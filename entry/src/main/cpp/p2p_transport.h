#ifndef NERVE_P2P_TRANSPORT_H
#define NERVE_P2P_TRANSPORT_H

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <sys/types.h>

namespace nerve {

// App 到 Daemon 的 WebRTC 连接。SSH 和 Mosh 仍各自使用原有的加密协议。
class P2pTransport final {
public:
    explicit P2pTransport(const std::string &stun);
    ~P2pTransport();
    std::string Offer() const;
    void SetAnswer(const std::string &sdp);
    int State() const;
    int OpenSsh();
    void ForwardMosh(int port);
    ssize_t ReadMosh(uint8_t *bytes, size_t capacity);
    void SendMosh(const uint8_t *bytes, size_t length) const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace nerve

#endif
