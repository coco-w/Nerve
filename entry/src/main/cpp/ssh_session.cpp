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
#include <stdexcept>
#include <sys/socket.h>
#include <unistd.h>

namespace nerve {
namespace {

constexpr int CONNECT_TIMEOUT_MS = 8000;
constexpr int SSH_REQUEST_TIMEOUT_MS = 8000;
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
    if (options.host.empty() || options.username.empty() || options.port < 1 || options.port > 65535) {
        throw std::runtime_error("请检查 SSH 地址、端口和用户名。");
    }
    if (!IsSessionName(options.zellijSession)) {
        throw std::runtime_error("Zellij 会话名含有不支持的字符。");
    }
    ValidateSize(options.size);

    static const int initResult = libssh2_init(0);
    if (initResult != 0) {
        throw std::runtime_error("SSH 库初始化失败。");
    }
    auto connection = std::unique_ptr<SshSession>(new SshSession());
    connection->socket_ = ConnectSocket(options.host, options.port);
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
    // 在发出任何用户认证请求之前校验握手使用的主机公钥。
    connection->VerifyFingerprint(options.fingerprint);
    connection->Authenticate(options);
    connection->OpenPty(options);
    libssh2_session_set_blocking(connection->session_, 0);
    return connection;
}

void SshSession::VerifyFingerprint(const std::string &expected) const
{
    const char *digest = libssh2_hostkey_hash(session_, LIBSSH2_HOSTKEY_HASH_SHA256);
    if (!digest) {
        throw std::runtime_error("无法读取 SSH 主机指纹。");
    }
    // 与 OpenSSH ssh-keygen -E sha256 输出一致，省略 Base64 末尾的等号。
    std::array<unsigned char, 45> encoded {};
    EVP_EncodeBlock(encoded.data(), reinterpret_cast<const unsigned char *>(digest), 32);
    const std::string observed = "SHA256:" + std::string(reinterpret_cast<const char *>(encoded.data()), 43);
    if (expected != observed) {
        throw std::runtime_error("主机指纹不匹配。请在主机上核对后重试。收到的指纹：" + observed);
    }
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
    // 会话名已限制为普通标识符，远端命令仅附接指定的会话。
    if (options.zellijSession.empty()) {
        if (libssh2_channel_shell(channel_) != 0) {
            throw std::runtime_error("SSH 服务端未能启动交互式终端。");
        }
    } else {
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
