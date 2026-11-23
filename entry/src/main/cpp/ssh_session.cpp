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
// 固定端口续接允许服务端等到旧客户端离线，再重试一次绑定。
constexpr int MOSH_RECOVERY_TIMEOUT_MS = 15000;
constexpr int DAEMON_HEALTH_TIMEOUT_MS = 3200;
constexpr size_t MAX_DAEMON_HEALTH_BYTES = 1024;
constexpr size_t MAX_MOSH_START_BYTES = 4096;
constexpr int MAX_PTY_DIMENSION = 500;

// 状态文件只记录本安装、本主机所启动的进程身份，Mosh 密钥仍只走 SSH 握手。
constexpr char FIXED_MOSH_LAUNCHER[] = R"MOSH(
owner=$1
port=$2
shift 2
state_dir="${HOME}/.cache/nerve/mosh"
if [ -z "$HOME" ] || ! (umask 077; mkdir -p "$state_dir") 2>/dev/null; then
    exec "$@" 2>&1
fi
state_file="$state_dir/$owner-$port"
ssh_uid=$(id -u)

# 用账号、进程名和启动时间识别 Mosh，避免把复用的 PID 当作旧连接。
mosh_identity() {
    case "$1" in ''|*[!0-9]*|0*|1) return 1 ;; esac
    LC_ALL=C TZ=UTC ps -p "$1" -o uid= -o stat= -o lstart= -o comm= 2>/dev/null |
        awk -v uid="$ssh_uid" '$1 == uid && $2 !~ /^Z/ && $NF ~ /(^|\/)mosh-server$/ { print $3, $4, $5, $6, $7 }'
}

start_mosh() {
    status=0
    output=$("$@" 2>&1) || status=$?
}

old_pid=''
old_identity=''
if [ -f "$state_file" ] && [ ! -L "$state_file" ]; then
    { IFS= read -r old_pid && IFS= read -r old_identity; } < "$state_file"
fi

# SIGUSR1 只在 Mosh 确认一段时间未收到客户端状态时触发退出。
export MOSH_SERVER_SIGNAL_TMOUT=6
start_mosh "$@"
if [ "$status" -eq 1 ] && [ -n "$old_identity" ] && [ "$(mosh_identity "$old_pid")" = "$old_identity" ]; then
    case "$output" in *'Network exception: bind: Address already in use'*)
        for attempt in 1 2 3 4 5 6 7 8 9; do
            [ "$(mosh_identity "$old_pid")" = "$old_identity" ] || break
            kill -USR1 "$old_pid" 2>/dev/null || break
            sleep 1
        done
        if [ "$(mosh_identity "$old_pid")" != "$old_identity" ]; then
            start_mosh "$@"
        fi
    ;; esac
fi

# 先原子写入进程记录，再交付握手票据，确保 App 随即退出也能续接。
if [ "$status" -eq 0 ]; then
    pid=$(printf '%s\n' "$output" | sed -n 's/^\[mosh-server detached, pid = \([0-9][0-9]*\)\]$/\1/p')
    identity=$(mosh_identity "$pid")
    if [ -n "$identity" ] && tmp=$(mktemp "$state_file.XXXXXX" 2>/dev/null); then
        if ! { printf '%s\n%s\n' "$pid" "$identity" > "$tmp" && mv -f "$tmp" "$state_file"; }; then
            rm -f "$tmp"
        fi
    fi
fi
printf '%s\n' "$output"
exit "$status"
)MOSH";

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

std::string ShellQuote(const std::string &text)
{
    std::string quoted = "'";
    for (char ch : text) {
        if (ch == '\'') {
            quoted += "'\"'\"'";
        } else {
            quoted += ch;
        }
    }
    return quoted + "'";
}

// SSH 和 Mosh 使用相同的会话命令，通知仍由开发机的 Nerve CLI 校验归属。
std::string TerminalCommand(const ConnectOptions &options)
{
    if (!options.pushLink.empty()) {
        const auto &link = options.pushLink;
        return "if ! command -v nerve >/dev/null 2>&1; then "
            "echo \"SSH 用户的 PATH 中没有 nerve。请在主机安装 Nerve CLI 后重试。\"; exit 127; fi; "
            "exec nerve attach-event " + link.substr(0, 36) + " " + link.substr(37);
    }
    if (options.zellijSession.empty()) {
        return {};
    }
    // 会话名在进入此处前已校验，检查窗格列表以排除已停止的同名会话。
    const auto &name = options.zellijSession;
    return "if ! command -v zellij >/dev/null 2>&1; then "
        "echo \"SSH 用户的 PATH 中没有 zellij。\"; exit 127; fi; "
        "case \"$(zellij --session " + name + " action list-panes --json 2>/dev/null)\" in "
        "\\[*) ;; *) echo \"找不到正在运行的 Zellij 会话：" + name + "\"; exit 1 ;; esac; "
        "exec zellij attach " + name + " options --on-force-close detach";
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
    if (options.moshPort < 0 || options.moshPort > 65535) {
        throw std::runtime_error("Mosh UDP 端口无效。");
    }
    // 限制本地安装标识的字符，供远端固定目录下的文件名使用。
    static const std::regex moshOwner("[a-f0-9]{32}-[1-9][0-9]{0,15}");
    if (!options.moshOwner.empty() && !std::regex_match(options.moshOwner, moshOwner)) {
        throw std::runtime_error("Mosh 续接标识无效。");
    }
    ValidateSize(options.size);

    auto connection = Handshake(options.host, options.port, options.peer);
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
    if (options.useMosh) {
        connection->OpenMosh(options);
        connection->CloseSsh();
    } else {
        connection->OpenPty(options);
        libssh2_session_set_blocking(connection->session_, 0);
    }
    return connection;
}

std::string SshSession::ProbeHostKey(const std::string &host, int port, const std::shared_ptr<P2pTransport> &peer)
{
    // 首次连接只进行握手和取指纹，随后关闭临时连接。
    return Handshake(host, port, peer)->Fingerprint();
}

std::unique_ptr<SshSession> SshSession::Handshake(const std::string &host, int port,
    const std::shared_ptr<P2pTransport> &peer)
{
    if (host.empty() || host.find('\0') != std::string::npos || port < 1 || port > 65535) {
        throw std::runtime_error("请检查 SSH 主机地址和端口。");
    }
    static const int initResult = libssh2_init(0);
    if (initResult != 0) {
        throw std::runtime_error("SSH 库初始化失败。");
    }
    auto connection = std::unique_ptr<SshSession>(new SshSession());
    connection->peer_ = peer;
    connection->socket_ = peer ? peer->OpenSsh() : ConnectSocket(host, port);
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

int SshSession::RunCommand(const std::string &command, std::string &output, int timeout, size_t limit) const
{
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout);
    const auto updateTimeout = [&]() {
        const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
            deadline - std::chrono::steady_clock::now()).count();
        if (remaining <= 0) {
            return false;
        }
        libssh2_session_set_timeout(session_, static_cast<long>(remaining));
        return true;
    };
    const auto release = [&](LIBSSH2_CHANNEL *channel) {
        // 短命令结束后释放通道，清理只短暂等待。
        libssh2_session_set_timeout(session_, 100);
        libssh2_channel_free(channel);
        libssh2_session_set_timeout(session_, SSH_REQUEST_TIMEOUT_MS);
    };
    if (!updateTimeout()) {
        return -1;
    }
    std::unique_ptr<LIBSSH2_CHANNEL, decltype(release)> channel(libssh2_channel_open_session(session_), release);
    if (!channel || libssh2_channel_handle_extended_data2(channel.get(), LIBSSH2_CHANNEL_EXTENDED_DATA_IGNORE) != 0 ||
        !updateTimeout() || libssh2_channel_exec(channel.get(), command.c_str()) != 0) {
        libssh2_session_set_timeout(session_, SSH_REQUEST_TIMEOUT_MS);
        return -1;
    }

    // 标准错误和过长输出不会进入界面，启动密钥也不会混入终端内容。
    output.resize(limit + 1, '\0');
    size_t length = 0;
    while (length < output.size() && updateTimeout()) {
        const ssize_t count = libssh2_channel_read(channel.get(), output.data() + length, output.size() - length);
        if (count <= 0) {
            output.resize(length);
            return count == 0 && libssh2_channel_eof(channel.get()) ?
                libssh2_channel_get_exit_status(channel.get()) : -1;
        }
        length += static_cast<size_t>(count);
    }
    return -1;
}

std::string SshSession::ReadDaemonHealth() const
{
    std::string output;
    const int status = RunCommand("/bin/sh -c 'command -v nerve >/dev/null 2>&1 && exec nerve health'",
        output, DAEMON_HEALTH_TIMEOUT_MS, MAX_DAEMON_HEALTH_BYTES);
    return status == 0 ? output : std::string();
}

void SshSession::OpenMosh(const ConnectOptions &options)
{
    // -s 让服务端使用 SSH 到达的接口，避免在多网卡主机上从其他地址回复。
    std::string script =
        "command -v mosh-server >/dev/null 2>&1 || { echo NERVE_MOSH_UNAVAILABLE; exit 127; }; "
        "if [ \"$(locale charmap 2>/dev/null)\" != UTF-8 ]; then "
        "for lang in C.UTF-8 en_US.UTF-8; do "
        "if [ \"$(LC_ALL=$lang locale charmap 2>/dev/null)\" = UTF-8 ]; then export LC_ALL=$lang; break; fi; "
        "done; fi; "
        // 保留远端设置，默认回收异常退出的客户端遗留的服务端进程。
        "export MOSH_SERVER_NETWORK_TMOUT=\"${MOSH_SERVER_NETWORK_TMOUT:-86400}\"; ";
    std::string command = "mosh-server new -s -c 256";
    if (options.moshPort > 0) {
        command += " -p " + std::to_string(options.moshPort);
    }
    const std::string terminal = TerminalCommand(options);
    if (!terminal.empty()) {
        command += " -- /bin/sh -c " + ShellQuote(terminal);
    }
    const bool recover = options.moshPort > 0 && !options.moshOwner.empty() && !peer_;
    // 收集 mosh-server 的启动诊断，只向界面返回已识别的错误，不转发原始输出。
    if (recover) {
        script += "exec /bin/sh -c " + ShellQuote(FIXED_MOSH_LAUNCHER) + " nerve-mosh " +
            ShellQuote(options.moshOwner) + " " + std::to_string(options.moshPort) + " " + command;
    } else {
        script += "exec " + command + " 2>&1";
    }
    std::string output;
    const int status = RunCommand("/bin/sh -c " + ShellQuote(script), output,
        recover ? MOSH_RECOVERY_TIMEOUT_MS : SSH_REQUEST_TIMEOUT_MS, MAX_MOSH_START_BYTES);
    if (status == 127 || output == "NERVE_MOSH_UNAVAILABLE\n") {
        ClearSecret(output);
        throw std::runtime_error("在开发机的 SSH PATH 中找不到 mosh-server，请安装 Mosh 或选择 SSH。");
    }
    // 固定端口冲突时，mosh-server 在返回会话票据前就会报告绑定失败。
    const bool portInUse = status == 1 && options.moshPort > 0 &&
        output.find("Network exception: bind: Address already in use") != std::string::npos;
    // 官方 mosh-server 的响应给出端口和 16 字节会话密钥的无填充 Base64。
    static const std::regex ticket(R"((^|\n)MOSH CONNECT ([0-9]{1,5}) ([A-Za-z0-9+/]{21}[AQgw])\r?(\n|$))");
    std::smatch match;
    if (status == 0 && std::regex_search(output, match, ticket)) {
        moshPort_ = std::stoi(match[2].str());
        moshKey_.assign(match[3].first, match[3].second);
    }
    ClearSecret(output);
    if (portInUse) {
        throw std::runtime_error("开发机的 Mosh UDP " + std::to_string(options.moshPort) +
            " 已被占用。请先释放该端口，再重试。");
    }
    if (moshKey_.empty() || moshPort_ < 1 || moshPort_ > 65535 ||
        (options.moshPort > 0 && moshPort_ != options.moshPort)) {
        throw std::runtime_error("启动 mosh-server 失败，请检查 UDP 端口和开发机的 UTF-8 环境。");
    }
    if (peer_) {
        peer_->ForwardMosh(moshPort_);
    } else {
        mosh_ = std::make_unique<MoshUdp>(socket_, moshPort_);
    }
}

void SshSession::ClearMoshKey()
{
    ClearSecret(moshKey_);
}

void SshSession::SendMoshDatagram(const uint8_t *buffer, size_t length) const
{
    if (mosh_) {
        mosh_->Send(buffer, length);
    } else if (peer_ && moshPort_) {
        peer_->SendMosh(buffer, length);
    }
}

void SshSession::RebindMosh()
{
    if (mosh_) {
        mosh_->Rebind();
    }
}

void SshSession::ResumeMosh(const std::shared_ptr<P2pTransport> &peer)
{
    // 换网只替换数据通道，继续用同一个服务端端口和终端里的 Mosh 会话状态。
    if (!peer_ || !peer || !moshPort_) throw std::runtime_error("当前会话不支持 P2P 续接。");
    peer->ForwardMosh(moshPort_);
    peer_ = peer;
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
    const auto terminal = TerminalCommand(options);
    if (terminal.empty()) {
        if (libssh2_channel_shell(channel_) != 0) {
            throw std::runtime_error("SSH 服务端未能启动交互式终端。");
        }
    } else {
        // 使用 /bin/sh 解析固定条件语句，兼容远端的 Bash、Zsh 和 Fish 登录 Shell。
        const std::string command = "/bin/sh -c " + ShellQuote(terminal);
        if (libssh2_channel_exec(channel_, command.c_str()) != 0) {
            throw std::runtime_error(options.pushLink.empty() ? "SSH 服务端未能启动 Zellij 附接命令。" :
                "SSH 服务端未能启动通知会话。");
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
    if (mosh_) {
        return mosh_->Read(buffer, std::min(capacity, MOSH_MAX_DATAGRAM));
    }
    if (peer_ && moshPort_) {
        return peer_->ReadMosh(buffer, capacity);
    }
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
    ClearMoshKey();
    mosh_.reset();
    CloseSsh();
    peer_.reset();
}

void SshSession::CloseSsh()
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
