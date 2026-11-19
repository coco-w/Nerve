#include "p2p_transport.h"

#include <array>
#include <atomic>
#include <cerrno>
#include <cstring>
#include <deque>
#include <mutex>
#include <poll.h>
#include <stdexcept>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>

#include <rtc/rtc.hpp>

#include "mosh_udp.h"

namespace nerve {
namespace {

constexpr int POLL_MS = 20;
constexpr size_t SSH_QUEUE_LIMIT = 1024 * 1024;
constexpr size_t MAX_MOSH_PACKETS = 48;

struct SshPipeInput {
    std::mutex mutex;
    std::deque<rtc::binary> packets;
    size_t pending = 0;
    std::atomic<bool> overflow = false;
    std::atomic<bool> remoteClosed = false;
};

// 给 libssh2 提供一个普通非阻塞套接字，另一端泵送 DataChannel 上的有序字节。
class SshPipe final {
public:
    SshPipe(int fd, std::shared_ptr<rtc::DataChannel> channel) : fd_(fd), channel_(std::move(channel)) {}

    ~SshPipe()
    {
        stopped_ = true;
        shutdown(fd_, SHUT_RDWR);
        if (worker_.joinable()) worker_.join();
        close(fd_);
    }

    void Start()
    {
        // 回调只持有队列，避免最后一个引用在泵线程上释放并等待自己退出。
        const std::weak_ptr<SshPipeInput> weak = input_;
        channel_->onMessage([weak](rtc::message_variant message) {
            const auto input = weak.lock();
            auto *packet = std::get_if<rtc::binary>(&message);
            if (!input || !packet || packet->empty()) return;
            std::lock_guard<std::mutex> lock(input->mutex);
            if (input->pending + packet->size() > SSH_QUEUE_LIMIT) {
                input->overflow = true;
                return;
            }
            input->pending += packet->size();
            input->packets.push_back(std::move(*packet));
        });
        channel_->onClosed([weak]() {
            if (auto input = weak.lock()) input->remoteClosed = true;
        });
        worker_ = std::thread([this]() { Pump(); });
    }

private:
    bool Flush()
    {
        std::lock_guard<std::mutex> lock(input_->mutex);
        if (input_->packets.empty()) return !input_->remoteClosed;
        auto &next = input_->packets.front();
        const ssize_t sent = send(fd_, next.data() + offset_, next.size() - offset_, MSG_NOSIGNAL);
        if (sent < 0) return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR;
        offset_ += static_cast<size_t>(sent);
        input_->pending -= static_cast<size_t>(sent);
        if (offset_ == next.size()) {
            input_->packets.pop_front();
            offset_ = 0;
        }
        return true;
    }

    void Pump()
    {
        try {
            std::array<rtc::byte, 16 * 1024> buffer {};
            while (!stopped_ && !input_->overflow && Flush()) {
                const bool readable = channel_->isOpen() && channel_->bufferedAmount() < SSH_QUEUE_LIMIT / 2;
                pollfd event {fd_, static_cast<short>(readable ? POLLIN : 0), 0};
                const int ready = poll(&event, 1, POLL_MS);
                if (ready < 0 && errno != EINTR) break;
                if ((event.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) break;
                if (ready > 0 && (event.revents & POLLIN) != 0) {
                    const ssize_t size = recv(fd_, buffer.data(), buffer.size(), 0);
                    if (size > 0) channel_->send(buffer.data(), static_cast<size_t>(size));
                    else if (size == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) break;
                }
            }
            channel_->close();
        } catch (const std::exception &) {
            // SSH 由自己的套接字收到断开，异步回调中不抛出异常。
        }
        shutdown(fd_, SHUT_RDWR);
    }

    const int fd_;
    const std::shared_ptr<rtc::DataChannel> channel_;
    std::atomic<bool> stopped_ = false;
    const std::shared_ptr<SshPipeInput> input_ = std::make_shared<SshPipeInput>();
    size_t offset_ = 0;
    std::thread worker_;
};

struct MoshPackets {
    std::mutex mutex;
    std::deque<rtc::binary> received;
};

} // namespace

struct P2pTransport::Impl {
    std::shared_ptr<rtc::PeerConnection> peer;
    std::shared_ptr<rtc::DataChannel> control;
    std::shared_ptr<rtc::DataChannel> mosh;
    std::shared_ptr<MoshPackets> packets = std::make_shared<MoshPackets>();
    std::unique_ptr<SshPipe> ssh;
    std::mutex sshMutex;

    ~Impl()
    {
        ssh.reset();
        if (peer) peer->close();
    }
};

P2pTransport::P2pTransport(const std::string &stun) : impl_(std::make_unique<Impl>())
{
    rtc::Configuration configuration;
    if (!stun.empty()) configuration.iceServers.emplace_back(stun);
    configuration.disableAutoNegotiation = true;
    impl_->peer = std::make_shared<rtc::PeerConnection>(configuration);
    impl_->control = impl_->peer->createDataChannel("control");
    rtc::DataChannelInit moshOptions;
    moshOptions.reliability.unordered = true;
    moshOptions.reliability.maxRetransmits = 0;
    impl_->mosh = impl_->peer->createDataChannel("mosh", moshOptions);
    const std::weak_ptr<MoshPackets> packets = impl_->packets;
    impl_->mosh->onMessage([packets](rtc::message_variant message) {
        auto queue = packets.lock();
        auto *packet = std::get_if<rtc::binary>(&message);
        if (!queue || !packet || packet->empty() || packet->size() > MOSH_MAX_DATAGRAM) return;
        std::lock_guard<std::mutex> lock(queue->mutex);
        if (queue->received.size() >= MAX_MOSH_PACKETS) queue->received.pop_front();
        queue->received.push_back(std::move(*packet));
    });
    impl_->peer->setLocalDescription(rtc::Description::Type::Offer);
}

P2pTransport::~P2pTransport() = default;

std::string P2pTransport::Offer() const
{
    // 完整候选放进同一份 SDP，移动端只需交换一次 offer 和 answer。
    if (impl_->peer->gatheringState() != rtc::PeerConnection::GatheringState::Complete) return {};
    const auto description = impl_->peer->localDescription();
    return description ? description->generateSdp() : std::string();
}

void P2pTransport::SetAnswer(const std::string &sdp)
{
    impl_->peer->setRemoteDescription(rtc::Description(sdp, "answer"));
}

int P2pTransport::State() const
{
    const auto state = impl_->peer->state();
    if (state == rtc::PeerConnection::State::Failed || state == rtc::PeerConnection::State::Closed) return -1;
    return impl_->control->isOpen() && impl_->mosh->isOpen() ? 1 : 0;
}

int P2pTransport::OpenSsh()
{
    std::lock_guard<std::mutex> lock(impl_->sshMutex);
    if (State() != 1) throw std::runtime_error("P2P 数据通道尚未建立。");
    // 指纹探测和实际登录各用一条 SSH 字节流，二者使用同一条 P2P 连接。
    impl_->ssh.reset();
    auto channel = impl_->peer->createDataChannel("ssh");
    int sockets[2];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0, sockets) != 0) {
        throw std::runtime_error("无法创建 P2P SSH 通道。");
    }
    try {
        impl_->ssh = std::make_unique<SshPipe>(sockets[1], channel);
        impl_->ssh->Start();
    } catch (...) {
        if (impl_->ssh) impl_->ssh.reset();
        else close(sockets[1]);
        close(sockets[0]);
        throw;
    }
    return sockets[0];
}

void P2pTransport::ForwardMosh(int port)
{
    if (port < 60000 || port > 61000) throw std::runtime_error("P2P Mosh 端口超出开发机的默认范围。");
    if (State() != 1) throw std::runtime_error("P2P 数据通道已断开。");
    impl_->control->send("mosh:" + std::to_string(port));
}

ssize_t P2pTransport::ReadMosh(uint8_t *bytes, size_t capacity)
{
    auto &packets = *impl_->packets;
    std::lock_guard<std::mutex> lock(packets.mutex);
    if (packets.received.empty()) return 0;
    auto packet = std::move(packets.received.front());
    packets.received.pop_front();
    if (packet.size() > capacity) return 0;
    std::memcpy(bytes, packet.data(), packet.size());
    return static_cast<ssize_t>(packet.size());
}

void P2pTransport::SendMosh(const uint8_t *bytes, size_t length) const
{
    if (!impl_->mosh->isOpen() || impl_->mosh->bufferedAmount() > 16 * MOSH_MAX_DATAGRAM) return;
    try {
        impl_->mosh->send(reinterpret_cast<const rtc::byte *>(bytes), length);
    } catch (const std::exception &) {
        // 换网时允许丢失这些数据包，恢复后由 Mosh 重发必要的状态。
    }
}

} // namespace nerve
