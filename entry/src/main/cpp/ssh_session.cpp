#include "ssh_session.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <fcntl.h>
#include <netdb.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <poll.h>
#include <regex>
#include <stdexcept>
#include <sys/socket.h>
#include <unistd.h>

namespace nerve {
namespace {

constexpr int CONNECT_TIMEOUT_MS = 8000;
constexpr int SSH_REQUEST_TIMEOUT_MS = 8000;
constexpr int DAEMON_HEALTH_TIMEOUT_MS = 3200;
constexpr size_t MAX_DAEMON_HEALTH_BYTES = 1024;
constexpr int MAX_PTY_DIMENSION = 500;

bool IsAlphaNumeric(char ch)
{
    return (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9');
}

bool IsSessionName(const std::string &name)
{
    return name.empty() || (name.size() <= 128 && (IsAlphaNumeric(name.front()) || name.front() == '_') &&
        std::all_of(name.begin(), name.end(), [](char ch) {
            return IsAlphaNumeric(ch) || ch == '_' || ch == '-' || ch == '.';
        }));
}

bool IsPushLink(const std::string &value)
{
    // 与服务端标识格式一致。UUID 通过校验后才能进入固定的远端 CLI 命令。
    const std::string uuid = "[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}";
    static const std::regex link(uuid + ":" + uuid);
    return value.size() == 73 && std::regex_match(value, link);
}

void ValidateSize(PtySize size)
{
    if (size.columns < 2 || size.columns > MAX_PTY_DIMENSION || size.rows < 2 || size.rows > MAX_PTY_DIMENSION) {
        throw std::runtime_error("终端尺寸超出支持范围。");
    }
}

bool WaitForConnect(int fd, std::chrono::steady_clock::time_point deadline)
{
    pollfd event {fd, POLLOUT, 0};
    auto timeLeft = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now());
    while (timeLeft.count() > 0) {
        const int result = poll(&event, 1, static_cast<int>(timeLeft.count()));
        if (result > 0) {
            int error = 0;
            socklen_t length = sizeof(error);
            return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0;
        }
        if (result == 0 || errno != EINTR) {
            break;
        }
        timeLeft = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now());
    }
    return false;
}

int ConnectSocket(const std::string &host, int port)
{
    addrinfo hints {};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_NUMERICSERV;
    addrinfo *result = nullptr;
    if (getaddrinfo(host.c_str(), std::to_string(port).c_str(), &hints, &result) != 0) {
        throw std::runtime_error("无法解析主机地址。");
    }
    std::unique_ptr<addrinfo, decltype(&freeaddrinfo)> addresses(result, freeaddrinfo);
    // 所有候选地址共用同一个 TCP 连接超时，兼容 IPv4 和 IPv6。
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(CONNECT_TIMEOUT_MS);
    for (const auto *address = addresses.get(); address && std::chrono::steady_clock::now() < deadline;
         address = address->ai_next) {
        const int fd = socket(address->ai_family, address->ai_socktype | SOCK_CLOEXEC, address->ai_protocol);
        if (fd < 0) {
            continue;
        }
        if (fcntl(fd, F_SETFL, O_NONBLOCK) == 0) {
            if (connect(fd, address->ai_addr, address->ai_addrlen) == 0 ||
                (errno == EINPROGRESS && WaitForConnect(fd, deadline))) {
                return fd;
            }
        }
        close(fd);
    }
    throw std::runtime_error("无法连接 SSH 主机，请检查地址、端口和网络。");
}

void ClearSecret(std::string &value)
{
    if (!value.empty()) {
        OPENSSL_cleanse(value.data(), value.size());
        value.clear();
    }
}

} // namespace

void ConnectOptions::ClearCredentials()
{
    ClearSecret(password);
    ClearSecret(privateKey);
    ClearSecret(passphrase);
}

std::unique_ptr<SshSession> SshSession::Connect(const ConnectOptions &options)
{
    if (options.username.empty() || options.fingerprint.empty()) {
        throw std::runtime_error("SSH 登录需要用户名和已信任的主机密钥。");
    }
    if (!IsSessionName(options.zellijSession)) {
        throw std::runtime_error("Zellij 会话名含有不支持的字符。");
    }
    if (!options.pushLink.empty() && (!IsPushLink(options.pushLink) || !options.zellijSession.empty())) {
        throw std::runtime_error("通知关联标识无效。");
    }
    ValidateSize(options.size);

    auto connection = Handshake(options.host, options.port);
    // 首次信任后的新握手也必须校验指纹，且在发出任何认证请求之前比较。
    const std::string observed = connection->Fingerprint();
    if (observed != options.fingerprint) {
        throw HostKeyMismatch(observed);
    }
    connection->Authenticate(options);
    if (options.discoverDaemon) {
        // 从已验证并认证的 SSH 连接读取主机 ID，通知参数只用于选择会话。
        connection->daemonHealth_ = connection->ReadDaemonHealth();
        libssh2_session_set_timeout(connection->session_, SSH_REQUEST_TIMEOUT_MS);
    }
    connection->OpenPty(options);
    libssh2_session_set_blocking(connection->session_, 0);
    return connection;
}

std::string SshSession::ProbeHostKey(const std::string &host, int port)
{
    // 首次连接只进行握手和取指纹，随后关闭临时连接。
    return Handshake(host, port)->Fingerprint();
}

std::unique_ptr<SshSession> SshSession::Handshake(const std::string &host, int port)
{
    if (host.empty() || host.find('\0') != std::string::npos || port < 1 || port > 65535) {
        throw std::runtime_error("请检查 SSH 主机地址和端口。");
    }
    static const int initResult = libssh2_init(0);
    if (initResult != 0) {
        throw std::runtime_error("SSH 库初始化失败。");
    }
    auto connection = std::unique_ptr<SshSession>(new SshSession());
    connection->socket_ = ConnectSocket(host, port);
    connection->session_ = libssh2_session_init();
    if (!connection->session_) {
        throw std::runtime_error("无法分配 SSH 会话。");
    }
    libssh2_session_set_timeout(connection->session_, SSH_REQUEST_TIMEOUT_MS);
    // 多把主机密钥同时可用时优先使用 Ed25519，便于核对实际协商的指纹。
    if (libssh2_session_method_pref(connection->session_, LIBSSH2_METHOD_HOSTKEY,
        "ssh-ed25519,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521,rsa-sha2-512,rsa-sha2-256") != 0) {
        throw std::runtime_error("无法设置 SSH 主机密钥算法。");
    }
    if (libssh2_session_handshake(connection->session_, connection->socket_) != 0) {
        throw std::runtime_error("SSH 握手失败，请检查服务端是否支持 SSH。");
    }
    return connection;
}

std::string SshSession::Fingerprint() const
{
    const char *digest = libssh2_hostkey_hash(session_, LIBSSH2_HOSTKEY_HASH_SHA256);
    if (!digest) {
        throw std::runtime_error("无法读取 SSH 主机指纹。");
    }
    // 与 OpenSSH ssh-keygen -E sha256 输出一致，省略 Base64 末尾的等号。
    std::array<unsigned char, 45> encoded {};
    EVP_EncodeBlock(encoded.data(), reinterpret_cast<const unsigned char *>(digest), 32);
    return "SHA256:" + std::string(reinterpret_cast<const char *>(encoded.data()), 43);
}

void SshSession::Authenticate(const ConnectOptions &options) const
{
    const int result = options.privateKey.empty() ?
        libssh2_userauth_password_ex(session_, options.username.c_str(), options.username.size(),
            options.password.data(), options.password.size(), nullptr) :
        libssh2_userauth_publickey_frommemory(session_, options.username.c_str(), options.username.size(),
            nullptr, 0, options.privateKey.data(), options.privateKey.size(), options.passphrase.c_str());
    if (result != 0) {
        throw std::runtime_error("SSH 身份验证失败，请检查用户名、凭据和服务端认证方式。");
    }
}

std::string SshSession::ReadDaemonHealth() const
{
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(DAEMON_HEALTH_TIMEOUT_MS);
    const auto updateTimeout = [&]() {
        const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
            deadline - std::chrono::steady_clock::now()).count();
        if (remaining <= 0) {
            return false;
        }
        libssh2_session_set_timeout(session_, static_cast<long>(remaining));
        return true;
    };
    if (!updateTimeout()) {
        return {};
    }
    const auto release = [&](LIBSSH2_CHANNEL *channel) {
        // 探测失败时仍可继续打开终端，临时通道的清理只短暂等待。
        libssh2_session_set_timeout(session_, 100);
        libssh2_channel_free(channel);
    };
    std::unique_ptr<LIBSSH2_CHANNEL, decltype(release)> channel(libssh2_channel_open_session(session_), release);
    constexpr const char *command = "/bin/sh -c 'command -v nerve >/dev/null 2>&1 && exec nerve health'";
    if (!channel || !updateTimeout() || libssh2_channel_exec(channel.get(), command) != 0) {
        return {};
    }

    // 健康检查的 JSON 只交给应用解析，标准错误和过长输出不进入终端或绑定记录。
    std::array<char, MAX_DAEMON_HEALTH_BYTES + 1> bytes {};
    size_t length = 0;
    while (length < bytes.size() && updateTimeout()) {
        const ssize_t count = libssh2_channel_read(channel.get(), bytes.data() + length, bytes.size() - length);
        if (count <= 0) {
            return count == 0 && libssh2_channel_eof(channel.get()) &&
                libssh2_channel_get_exit_status(channel.get()) == 0 ? std::string(bytes.data(), length) : std::string();
        }
        length += static_cast<size_t>(count);
    }
    return {};
}

void SshSession::OpenPty(const ConnectOptions &options)
{
    channel_ = libssh2_channel_open_session(session_);
    if (!channel_ || libssh2_channel_request_pty_ex(channel_, "xterm-256color", 14, nullptr, 0,
        options.size.columns, options.size.rows, 0, 0) != 0) {
        throw std::runtime_error("SSH 服务端未能分配终端。");
    }
    if (libssh2_channel_handle_extended_data2(channel_, LIBSSH2_CHANNEL_EXTENDED_DATA_MERGE) != 0) {
        throw std::runtime_error("无法读取 SSH 终端的错误输出。");
    }
    if (!options.pushLink.empty()) {
        const auto &link = options.pushLink;
        const std::string command = "/bin/sh -c 'if ! command -v nerve >/dev/null 2>&1; then "
            "echo \"SSH 用户的 PATH 中没有 nerve。请在主机安装 Nerve CLI 后重试。\"; exit 127; fi; "
            "exec nerve attach-event " + link.substr(0, 36) + " " + link.substr(37) + "'";
        if (libssh2_channel_exec(channel_, command.c_str()) != 0) {
            throw std::runtime_error("SSH 服务端未能启动通知会话。");
        }
    } else if (options.zellijSession.empty()) {
        if (libssh2_channel_shell(channel_) != 0) {
            throw std::runtime_error("SSH 服务端未能启动交互式终端。");
        }
    } else {
        // 会话名已限制为普通标识符，远端命令仅附接指定的会话。
        // Zellij 0.46 的部分查询失败仍返回 0，检查精确会话是否返回 JSON 窗格列表。
        // 使用 /bin/sh 解析固定条件语句，兼容远端的 Bash、Zsh 和 Fish 登录 Shell。
        const std::string &name = options.zellijSession;
        const std::string command = "/bin/sh -c 'if ! command -v zellij >/dev/null 2>&1; then "
            "echo \"SSH 用户的 PATH 中没有 zellij。\"; exit 127; fi; "
            "case \"$(zellij --session " + name + " action list-panes --json 2>/dev/null)\" in "
            "\\[*) ;; *) echo \"找不到正在运行的 Zellij 会话：" + name + "\"; exit 1 ;; esac; "
            "exec zellij attach " + name + " options --on-force-close detach'";
        if (libssh2_channel_exec(channel_, command.c_str()) != 0) {
            throw std::runtime_error("SSH 服务端未能启动 Zellij 附接命令。");
        }
    }
}

SshSession::~SshSession()
{
    Close();
}

void SshSession::RequireOpen() const
{
    if (!channel_) {
        throw std::runtime_error("SSH 连接已关闭。");
    }
}

ssize_t SshSession::Read(uint8_t *buffer, size_t capacity)
{
    RequireOpen();
    const ssize_t bytes = libssh2_channel_read(channel_, reinterpret_cast<char *>(buffer), capacity);
    if (bytes > 0) {
        return bytes;
    }
    if (bytes == 0 || bytes == LIBSSH2_ERROR_EAGAIN) {
        return libssh2_channel_eof(channel_) == 1 ? -1 : 0;
    }
    throw std::runtime_error("SSH 终端读取失败，连接可能已中断。");
}

int SshSession::ExitStatus() const
{
    RequireOpen();
    return libssh2_channel_get_exit_status(channel_);
}

size_t SshSession::Write(const uint8_t *buffer, size_t length)
{
    RequireOpen();
    const ssize_t bytes = libssh2_channel_write(channel_, reinterpret_cast<const char *>(buffer), length);
    if (bytes == LIBSSH2_ERROR_EAGAIN) {
        return 0;
    }
    if (bytes < 0) {
        throw std::runtime_error("SSH 终端输入发送失败。");
    }
    return static_cast<size_t>(bytes);
}

bool SshSession::Resize(PtySize size)
{
    RequireOpen();
    ValidateSize(size);
    const int result = libssh2_channel_request_pty_size_ex(channel_, size.columns, size.rows, 0, 0);
    if (result == LIBSSH2_ERROR_EAGAIN) {
        return false;
    }
    if (result != 0) {
        throw std::runtime_error("SSH 终端尺寸同步失败。");
    }
    return true;
}

void SshSession::Close()
{
    if (socket_ >= 0) {
        // 关闭 TCP 端点后再释放协议资源，避免退出页面时阻塞。
        shutdown(socket_, SHUT_RDWR);
    }
    if (session_) {
        libssh2_session_set_blocking(session_, 0);
        libssh2_session_free(session_);
        session_ = nullptr;
        channel_ = nullptr;
    }
    if (socket_ >= 0) {
        close(socket_);
        socket_ = -1;
    }
}

} // namespace nerve
