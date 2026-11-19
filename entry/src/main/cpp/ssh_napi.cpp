#include <napi/native_api.h>

#include <array>
#include <cstring>
#include <stdexcept>

#include "ssh_session.h"

namespace {

constexpr size_t MAX_INPUT_BYTES = 16 * 1024;
constexpr size_t READ_CHUNK_BYTES = 32 * 1024;

void Check(napi_status status)
{
    if (status != napi_ok) {
        throw std::runtime_error("SSH 模块参数或运行状态无效。");
    }
}

template <size_t Count>
std::array<napi_value, Count> Arguments(napi_env env, napi_callback_info info)
{
    std::array<napi_value, Count> args {};
    size_t size = args.size();
    Check(napi_get_cb_info(env, info, &size, args.data(), nullptr, nullptr));
    if (size != args.size()) {
        throw std::runtime_error("SSH 模块参数数量无效。");
    }
    return args;
}

std::string StringProperty(napi_env env, napi_value options, const char *name, size_t maxLength)
{
    napi_value value;
    Check(napi_get_named_property(env, options, name, &value));
    size_t length = 0;
    Check(napi_get_value_string_utf8(env, value, nullptr, 0, &length));
    if (length > maxLength) {
        throw std::runtime_error("SSH 连接参数超出长度限制。");
    }
    std::string text(length, '\0');
    Check(napi_get_value_string_utf8(env, value, text.data(), length + 1, &length));
    return text;
}

int IntValue(napi_env env, napi_value value)
{
    int32_t number = 0;
    Check(napi_get_value_int32(env, value, &number));
    return number;
}

int IntProperty(napi_env env, napi_value options, const char *name)
{
    napi_value value;
    Check(napi_get_named_property(env, options, name, &value));
    return IntValue(env, value);
}

nerve::SshSession &Connection(napi_env env, napi_value value)
{
    void *handle = nullptr;
    Check(napi_get_value_external(env, value, &handle));
    return *static_cast<nerve::SshSession *>(handle);
}

template <typename Callback>
napi_value Call(napi_env env, Callback callback)
{
    try {
        return callback();
    } catch (const std::exception &error) {
        napi_throw_error(env, nullptr, error.what());
        return nullptr;
    }
}

struct ConnectRequest {
    nerve::ConnectOptions options {};
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::unique_ptr<nerve::SshSession> connection;
    std::string error;

    ~ConnectRequest() { options.ClearCredentials(); }
};

void ExecuteConnect(napi_env, void *data)
{
    auto &request = *static_cast<ConnectRequest *>(data);
    try {
        request.connection = nerve::SshSession::Connect(request.options);
    } catch (const std::exception &error) {
        request.error = error.what();
    }
    request.options.ClearCredentials();
}

void FinalizeConnection(napi_env, void *data, void *)
{
    delete static_cast<nerve::SshSession *>(data);
}

void CompleteConnect(napi_env env, napi_status status, void *data)
{
    std::unique_ptr<ConnectRequest> request(static_cast<ConnectRequest *>(data));
    napi_value value;
    if (status == napi_ok && request->connection &&
        napi_create_external(env, request->connection.get(), FinalizeConnection, nullptr, &value) == napi_ok) {
        // 连接成功后由 ArkTS 持有句柄，回收时关闭底层套接字。
        request->connection.release();
        napi_resolve_deferred(env, request->deferred, value);
    } else {
        const char *message = request->error.empty() ? "SSH 连接未能建立。" : request->error.c_str();
        napi_value text;
        if (napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &text) == napi_ok &&
            napi_create_error(env, nullptr, text, &value) == napi_ok) {
            napi_reject_deferred(env, request->deferred, value);
        }
    }
    napi_delete_async_work(env, request->work);
}

napi_value Connect(napi_env env, napi_callback_info info)
{
    return Call(env, [&]() {
        auto request = std::make_unique<ConnectRequest>();
        const napi_value options = Arguments<1>(env, info)[0];
        request->options.host = StringProperty(env, options, "host", 253);
        request->options.port = IntProperty(env, options, "port");
        request->options.username = StringProperty(env, options, "username", 256);
        request->options.fingerprint = StringProperty(env, options, "fingerprint", 50);
        request->options.zellijSession = StringProperty(env, options, "zellijSession", 128);
        request->options.pushLink = StringProperty(env, options, "pushLink", 73);
        request->options.password = StringProperty(env, options, "password", 4096);
        request->options.privateKey = StringProperty(env, options, "privateKey", 32768);
        request->options.passphrase = StringProperty(env, options, "passphrase", 4096);
        request->options.size = {IntProperty(env, options, "columns"), IntProperty(env, options, "rows")};

        // DNS、握手和认证在后台完成，终端的读写使用非阻塞调用。
        napi_value promise;
        napi_value name;
        Check(napi_create_promise(env, &request->deferred, &promise));
        Check(napi_create_string_utf8(env, "NerveSshConnect", NAPI_AUTO_LENGTH, &name));
        Check(napi_create_async_work(env, nullptr, name, ExecuteConnect, CompleteConnect, request.get(), &request->work));
        const napi_status scheduled = napi_queue_async_work(env, request->work);
        if (scheduled != napi_ok) {
            napi_delete_async_work(env, request->work);
            Check(scheduled);
        }
        request.release();
        return promise;
    });
}

napi_value Read(napi_env env, napi_callback_info info)
{
    return Call(env, [&]() {
        auto &connection = Connection(env, Arguments<1>(env, info)[0]);
        std::array<uint8_t, READ_CHUNK_BYTES> bytes;
        const ssize_t count = connection.Read(bytes.data(), bytes.size());
        napi_value value;
        if (count == 0) {
            Check(napi_get_undefined(env, &value));
            return value;
        }

        // 空 ArrayBuffer 表示 EOF，原始字节可保留跨包的 UTF-8 与 ANSI 序列。
        void *target = nullptr;
        const size_t length = count < 0 ? 0 : static_cast<size_t>(count);
        Check(napi_create_arraybuffer(env, length, &target, &value));
        if (length > 0) {
            std::memcpy(target, bytes.data(), length);
        }
        return value;
    });
}

napi_value Write(napi_env env, napi_callback_info info)
{
    return Call(env, [&]() {
        const auto args = Arguments<3>(env, info);
        void *buffer = nullptr;
        size_t length = 0;
        Check(napi_get_arraybuffer_info(env, args[1], &buffer, &length));
        const int offset = IntValue(env, args[2]);
        if (length > MAX_INPUT_BYTES || offset < 0 || static_cast<size_t>(offset) >= length) {
            throw std::runtime_error("SSH 终端输入超出支持范围。");
        }
        const size_t count = Connection(env, args[0]).Write(
            static_cast<const uint8_t *>(buffer) + offset, length - offset);
        napi_value value;
        Check(napi_create_uint32(env, count, &value));
        return value;
    });
}

napi_value Resize(napi_env env, napi_callback_info info)
{
    return Call(env, [&]() {
        const auto args = Arguments<3>(env, info);
        const bool complete = Connection(env, args[0]).Resize({IntValue(env, args[1]), IntValue(env, args[2])});
        napi_value value;
        Check(napi_get_boolean(env, complete, &value));
        return value;
    });
}

napi_value Disconnect(napi_env env, napi_callback_info info)
{
    return Call(env, [&]() {
        Connection(env, Arguments<1>(env, info)[0]).Close();
        napi_value value;
        Check(napi_get_undefined(env, &value));
        return value;
    });
}

napi_value Init(napi_env env, napi_value exports)
{
    const napi_property_descriptor properties[] = {
        {"connect", nullptr, Connect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"read", nullptr, Read, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"write", nullptr, Write, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resize", nullptr, Resize, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"disconnect", nullptr, Disconnect, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}

} // namespace

static napi_module nerveModule = {1, 0, nullptr, Init, "nerve_ssh", nullptr, {nullptr}};

extern "C" __attribute__((constructor)) void RegisterNerveSsh()
{
    napi_module_register(&nerveModule);
}
