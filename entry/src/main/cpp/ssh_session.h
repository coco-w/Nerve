#ifndef NERVE_SSH_SESSION_H
#define NERVE_SSH_SESSION_H

#include <cstddef>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <sys/types.h>

#include <libssh2.h>

namespace nerve {

struct PtySize {
    int columns;
    int rows;
};

struct ConnectOptions {
    std::string host;
    int port;
    std::string username;
    std::string fingerprint;
    std::string password;
    std::string privateKey;
    std::string passphrase;
    std::string zellijSession;
    PtySize size;
    std::string pushLink;
    bool discoverDaemon = false;

    // 本地认证参数只用于建立连接，握手完成后清理原生侧副本。
    void ClearCredentials();
};

// 携带本次握手的指纹，供界面显示并让用户核对主机密钥变化。
class HostKeyMismatch final : public std::runtime_error {
public:
    explicit HostKeyMismatch(const std::string &observed)
        : std::runtime_error("SSH 主机密钥已变化。"), fingerprint(observed) {}

    const std::string fingerprint;
};

class SshSession final {
public:
    static std::string ProbeHostKey(const std::string &host, int port);
    static std::unique_ptr<SshSession> Connect(const ConnectOptions &options);
    ~SshSession();

    SshSession(const SshSession &) = delete;
    SshSession &operator=(const SshSession &) = delete;

    // 读返回 0 表示暂时无数据，-1 表示远端结束。
    ssize_t Read(uint8_t *buffer, size_t capacity);
    const std::string &DaemonHealth() const { return daemonHealth_; }
    int ExitStatus() const;
    size_t Write(const uint8_t *buffer, size_t length);
    bool Resize(PtySize size);
    void Close();

private:
    SshSession() = default;
    static std::unique_ptr<SshSession> Handshake(const std::string &host, int port);
    std::string Fingerprint() const;
    void Authenticate(const ConnectOptions &options) const;
    std::string ReadDaemonHealth() const;
    void OpenPty(const ConnectOptions &options);
    void RequireOpen() const;

    int socket_ = -1;
    LIBSSH2_SESSION *session_ = nullptr;
    LIBSSH2_CHANNEL *channel_ = nullptr;
    std::string daemonHealth_;
};

} // namespace nerve

#endif
