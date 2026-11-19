#include "mosh_udp.h"

#include <cstring>
#include <netinet/in.h>
#include <stdexcept>
#include <unistd.h>

namespace nerve {

MoshUdp::MoshUdp(int sshSocket, int port)
{
    if (getpeername(sshSocket, reinterpret_cast<sockaddr *>(&peer_), &peerLength_) != 0) {
        throw std::runtime_error("无法获取 Mosh 开发机地址。");
    }
    switch (peer_.ss_family) {
        case AF_INET:
            reinterpret_cast<sockaddr_in *>(&peer_)->sin_port = htons(port);
            break;
        case AF_INET6:
            reinterpret_cast<sockaddr_in6 *>(&peer_)->sin6_port = htons(port);
            break;
        default:
            throw std::runtime_error("Mosh 需要 IPv4 或 IPv6 地址。");
    }
    Rebind();
    if (socket_ < 0) {
        throw std::runtime_error("无法创建 Mosh UDP 套接字。");
    }
}

MoshUdp::~MoshUdp()
{
    if (socket_ >= 0) {
        close(socket_);
    }
}

void MoshUdp::Rebind()
{
    // 保持协议状态，换用未绑定网卡的新 UDP 套接字以适应切网和端口变化。
    const int next = socket(peer_.ss_family, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (next >= 0) {
        if (socket_ >= 0) {
            close(socket_);
        }
        socket_ = next;
    }
}

bool MoshUdp::IsPeer(const sockaddr_storage &source) const
{
    if (source.ss_family != peer_.ss_family) {
        return false;
    }
    if (source.ss_family == AF_INET) {
        const auto &reply = reinterpret_cast<const sockaddr_in &>(source);
        const auto &server = reinterpret_cast<const sockaddr_in &>(peer_);
        return reply.sin_port == server.sin_port && reply.sin_addr.s_addr == server.sin_addr.s_addr;
    }
    const auto &reply = reinterpret_cast<const sockaddr_in6 &>(source);
    const auto &server = reinterpret_cast<const sockaddr_in6 &>(peer_);
    return reply.sin6_port == server.sin6_port && reply.sin6_scope_id == server.sin6_scope_id &&
        std::memcmp(&reply.sin6_addr, &server.sin6_addr, sizeof(in6_addr)) == 0;
}

ssize_t MoshUdp::Read(uint8_t *buffer, size_t capacity) const
{
    // 每次有界地丢弃无关 datagram，避免持续的 UDP 流量阻塞界面。
    for (int i = 0; i < 8; ++i) {
        sockaddr_storage source {};
        socklen_t length = sizeof(source);
        const ssize_t received = recvfrom(socket_, buffer, capacity, MSG_TRUNC,
            reinterpret_cast<sockaddr *>(&source), &length);
        if (received < 0) {
            break;
        }
        if (received >= 24 && static_cast<size_t>(received) <= capacity && IsPeer(source)) {
            return received;
        }
    }
    return 0;
}

void MoshUdp::Send(const uint8_t *bytes, size_t length) const
{
    // UDP 写失败等同于丢包，Mosh 的状态同步负责重发，切网时保留会话。
    sendto(socket_, bytes, length, 0, reinterpret_cast<const sockaddr *>(&peer_), peerLength_);
}

} // namespace nerve
