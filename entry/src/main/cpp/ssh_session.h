#ifndef NERVE_SSH_SESSION_H
#define NERVE_SSH_SESSION_H

#include <cstddef>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <sys/types.h>

#include <libssh2.h>

#include "mosh_udp.h"
#include "p2p_transport.h"

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
    bool useMosh = false;
    // 0 由 mosh-server 在默认范围内分配，正数指定单个可达的 UDP 端口。
    int moshPort = 0;
    std::shared_ptr<P2pTransport> peer;

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
    static std::string ProbeHostKey(const std::string &host, int port,
        const std::shared_ptr<P2pTransport> &peer = {});
    static std::unique_ptr<SshSession> Connect(const ConnectOptions &options);
    ~SshSession();

    SshSession(const SshSession &) = delete;
    SshSession &operator=(const SshSession &) = delete;

    // 读返回 0 表示暂时无数据，-1 表示远端结束。
    ssize_t Read(uint8_t *buffer, size_t capacity);
    const std::string &DaemonHealth() const { return daemonHealth_; }
    const std::string &MoshKey() const { return moshKey_; }
    int MoshPort() const { return moshPort_; }
    void ClearMoshKey();
    void SendMoshDatagram(const uint8_t *buffer, size_t length) const;
    void RebindMosh();
    void ResumeMosh(const std::shared_ptr<P2pTransport> &peer);
    int ExitStatus() const;
    size_t Write(const uint8_t *buffer, size_t length);
    bool Resize(PtySize size);
    void Close();

private:
    SshSession() = default;
    static std::unique_ptr<SshSession> Handshake(const std::string &host, int port,
        const std::shared_ptr<P2pTransport> &peer);
    std::string Fingerprint() const;
    void Authenticate(const ConnectOptions &options) const;
    // 在已认证的 SSH 上读取短命令输出，返回退出码，-1 表示传输失败。
    int RunCommand(const std::string &command, std::string &output, int timeout, size_t limit) const;
    std::string ReadDaemonHealth() const;
    void OpenPty(const ConnectOptions &options);
    void OpenMosh(const ConnectOptions &options);
    void RequireOpen() const;
    void CloseSsh();

    int socket_ = -1;
    LIBSSH2_SESSION *session_ = nullptr;
    LIBSSH2_CHANNEL *channel_ = nullptr;
    std::string daemonHealth_;
    std::unique_ptr<MoshUdp> mosh_;
    std::shared_ptr<P2pTransport> peer_;
    std::string moshKey_;
    int moshPort_ = 0;
};

} // namespace nerve

#endif
