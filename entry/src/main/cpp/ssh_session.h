#ifndef NERVE_SSH_SESSION_H
#define NERVE_SSH_SESSION_H

#include <cstddef>
#include <cstdint>
#include <memory>
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

    // 本地认证参数只用于建立连接，握手完成后清理原生侧副本。
    void ClearCredentials();
};

class SshSession final {
public:
    static std::unique_ptr<SshSession> Connect(const ConnectOptions &options);
    ~SshSession();

    SshSession(const SshSession &) = delete;
    SshSession &operator=(const SshSession &) = delete;

    // 读返回 0 表示暂时无数据，-1 表示远端结束。
    ssize_t Read(uint8_t *buffer, size_t capacity);
    size_t Write(const uint8_t *buffer, size_t length);
    bool Resize(PtySize size);
    void Close();

private:
    SshSession() = default;
    void VerifyFingerprint(const std::string &expected) const;
    void Authenticate(const ConnectOptions &options) const;
    void OpenPty(const ConnectOptions &options);
    void RequireOpen() const;

    int socket_ = -1;
    LIBSSH2_SESSION *session_ = nullptr;
    LIBSSH2_CHANNEL *channel_ = nullptr;
};

} // namespace nerve

#endif
