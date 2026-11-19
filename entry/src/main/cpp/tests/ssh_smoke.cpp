#include "ssh_session.h"

#include <array>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <thread>

namespace {

using namespace std::chrono_literals;

// 等待指定终端输出，避免写入命令被终端回显时误判测试通过。
void Expect(nerve::SshSession &session, const std::string &output)
{
    const auto deadline = std::chrono::steady_clock::now() + 10s;
    std::array<uint8_t, 8192> buffer {};
    std::string received;
    while (std::chrono::steady_clock::now() < deadline) {
        const ssize_t bytes = session.Read(buffer.data(), buffer.size());
        if (bytes < 0) {
            break;
        }
        received.append(reinterpret_cast<const char *>(buffer.data()), bytes);
        if (received.find(output) != std::string::npos) {
            return;
        }
        if (received.size() > 64 * 1024) {
            received.erase(0, 32 * 1024);
        }
        std::this_thread::sleep_for(20ms);
    }
    throw std::runtime_error("未收到预期终端输出：" + output + "。收到的末尾内容：" +
        received.substr(received.size() > 512 ? received.size() - 512 : 0));
}

void Send(nerve::SshSession &session, const std::string &input)
{
    const auto deadline = std::chrono::steady_clock::now() + 5s;
    size_t sent = 0;
    while (sent < input.size() && std::chrono::steady_clock::now() < deadline) {
        sent += session.Write(reinterpret_cast<const uint8_t *>(input.data()) + sent, input.size() - sent);
        std::this_thread::sleep_for(20ms);
    }
    if (sent != input.size()) {
        throw std::runtime_error("联调输入发送超时。");
    }
}

void CheckFingerprint(nerve::ConnectOptions &options)
{
    const std::string expected = options.fingerprint;
    // 以 OpenSSH 生成的指纹为准，核对探测与登录握手使用同一把主机密钥。
    if (nerve::SshSession::ProbeHostKey(options.host, options.port) != expected) {
        throw std::runtime_error("首次连接探测得到的主机指纹不匹配。");
    }
    options.fingerprint[7] = options.fingerprint[7] == 'A' ? 'B' : 'A';
    try {
        nerve::SshSession::Connect(options);
    } catch (const nerve::HostKeyMismatch &error) {
        options.fingerprint = expected;
        if (error.fingerprint != expected) {
            throw std::runtime_error("密钥变化提示未返回本次握手的实际指纹。");
        }
        return;
    }
    throw std::runtime_error("错误的主机指纹被接受。");
}

} // namespace

int main(int argc, char **argv)
{
    if (argc < 6 || argc > 7 || std::string(argv[4]).size() != 50) {
        std::cerr << "用法：nerve_ssh_smoke 主机 端口 用户 SHA256:指纹 私钥文件 [Zellij会话名]\n";
        return 2;
    }

    try {
        std::ifstream key(argv[5], std::ios::binary);
        if (!key) {
            throw std::runtime_error("无法读取联调私钥文件。");
        }
        const char *passphrase = std::getenv("NERVE_SMOKE_KEY_PASSPHRASE");
        nerve::ConnectOptions options {argv[1], std::stoi(argv[2]), argv[3], argv[4], "",
            std::string(std::istreambuf_iterator<char>(key), {}), passphrase ? passphrase : "",
            argc == 7 ? argv[6] : "", {100, 34}};
        CheckFingerprint(options);
        auto session = nerve::SshSession::Connect(options);
        options.ClearCredentials();
        if (argc == 7) {
            // 等待 Zellij 接管终端后向已有窗格发送命令。
            Expect(*session, "NERVE_ZELLIJ_READY");
            Send(*session, "printf 'NERVE_%s\\n' ATTACHED\r");
            Expect(*session, "NERVE_ATTACHED");
        } else {
            Send(*session, "printf 'NERVE_%s:' SIZE; stty size\r");
            Expect(*session, "NERVE_SIZE:34 100");
            const auto deadline = std::chrono::steady_clock::now() + 5s;
            while (!session->Resize({97, 31})) {
                if (std::chrono::steady_clock::now() >= deadline) {
                    throw std::runtime_error("联调终端尺寸同步超时。");
                }
                std::this_thread::sleep_for(20ms);
            }
            Send(*session, "printf 'NERVE_%s:' RESIZED; stty size; printf 'NERVE_%s\\n' 中文\r");
            Expect(*session, "NERVE_RESIZED:31 97\r\nNERVE_中文");
        }
        session->Close();
        std::cout << (argc == 7 ? "主机指纹校验、私钥与已有 Zellij 交互通过。\n" :
            "主机指纹校验、私钥、UTF-8 输入输出和 PTY 尺寸同步通过。\n");
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
