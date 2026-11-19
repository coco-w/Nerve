#ifndef NERVE_MOSH_UDP_H
#define NERVE_MOSH_UDP_H

#include <cstddef>
#include <cstdint>
#include <sys/socket.h>

namespace nerve {

// Mosh 普通分片小于链路 MTU，这个上限为 IPv4/IPv6 数据报留出余量。
constexpr size_t MOSH_MAX_DATAGRAM = 2048;

// UDP 始终直连完成 SSH 认证的地址，端口由该主机上的 mosh-server 分配。
class MoshUdp final {
public:
    MoshUdp(int sshSocket, int port);
    ~MoshUdp();

    MoshUdp(const MoshUdp &) = delete;
    MoshUdp &operator=(const MoshUdp &) = delete;

    ssize_t Read(uint8_t *buffer, size_t capacity) const;
    void Send(const uint8_t *bytes, size_t length) const;
    void Rebind();

private:
    bool IsPeer(const sockaddr_storage &source) const;

    sockaddr_storage peer_ {};
    socklen_t peerLength_ = sizeof(peer_);
    int socket_ = -1;
};

} // namespace nerve

#endif
