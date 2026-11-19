# Nerve

Nerve 是面向 HarmonyOS 的远程开发工具。手机通过 SSH 直连开发机的 Zellij 会话。主机上的 Nerve Daemon 采集 Codex Hooks 和 Oh My Pi（OMP）扩展事件，独立的 Push Gateway 负责把需要提醒的事件交给 Huawei Push Kit。

## 当前进度

- `entry/` 是 HarmonyOS 原生应用。手机通过 libssh2 直连主机，终端由本地打包的 xterm.js 绘制。可打开 Shell 或接入已有 Zellij 会话。连接页和终端默认使用内置的 Maple Mono NF CN 7.9。 [字体发布](https://github.com/subframe7536/maple-font/releases/tag/v7.9) · [字体许可证](entry/src/main/resources/rawfile/licenses/maple-mono-OFL)
- `daemon/` 是 Node.js + TypeScript PoC。在同一系统用户下通过 Unix Socket 采集事件，写入 SQLite，并提供事件查询和 Zellij 会话、窗格列表。
- Push Gateway 是独立运行的服务。Daemon 和 Gateway 分别用 SQLite 保存待发送通知，支持本地收件联调和 Huawei Push Kit V3。鸿蒙端提供通知授权、设备令牌导出和通知关联会话入口。后续验证 Mosh 和真机锁屏收通知。

## 手机连接 SSH

1. 确认手机能访问开发机的 SSH 服务。使用运行 Zellij 的同一个远端用户登录。自动附接按 Zellij 0.46.0 联调，要求 `zellij` 位于该用户远端命令的 `PATH` 中。会话名可以用 `zellij list-sessions` 查看。
2. 填写主机、端口和用户名。可输入密码，或通过文件选择器打开 OpenSSH 或 PEM 私钥并按需输入口令。凭据只用于本次连接。填写已有会话的完整名称可直接附接，留空会打开 Shell，也可在 Shell 中手动运行 `zellij attach <会话名>`。
3. 首次连接时 Nerve 会显示主机指纹，确认后即可登录。同一主机和端口下次会自动校验已保存的指纹。密钥变化时会阻止登录并显示新旧指纹，核对后可更新信任，再填写凭据连接。需要在开发机核对指纹时，OpenSSH 的常见配置可用 `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256`。Nerve 优先协商 Ed25519，服务端使用其他密钥时请核对对应的公钥文件。
4. 点击终端弹出软键盘。底部提供 Ctrl、Esc、Tab 和方向键。点一次 Ctrl 再输入字母可发送组合键。窗口尺寸变化时会同步给主机。点击「断开」退出当前 SSH 连接，已有 Zellij 会话继续运行。

### 构建与联调

使用 DevEco Studio 或在项目根目录运行 `devecocli build`。HAP 位于 `entry/build/default/outputs/default/`，包含手机用的 arm64-v8a 和模拟器用的 x86_64 原生库。安装到设备前请先在本地配置 Nerve 的调试签名。

首次原生构建需获取固定版本的 libssh2 1.11.1 和 AWS-LC 5.15.0。CMake 会校验归档的 SHA-256。网络受限时，把原始归档按 `libssh2-1.11.1.tar.gz` 和 `aws-lc-5.15.0.tar.gz` 命名，将 `NERVE_SSH_ARCHIVE_DIR` 指向所在目录后启动构建。使用 Hvigor 常驻进程时，先重启当前项目的构建进程以读取新的环境变量。终端渲染资源随 HAP 打包，其中 xterm.js 为 6.0.0，FitAddon 为 0.11.0。

原生联调程序从 Linux 构建运行。请用独立的测试 SSH 账户或临时授权的测试密钥。给定会话名时，程序会在其当前窗格中输入测试命令，窗格需运行 Shell 且先显示过 `NERVE_ZELLIJ_READY`。

~~~bash
cmake -S entry/src/main/cpp -B /tmp/nerve-ssh-build -DNERVE_BUILD_SMOKE_TEST=ON
cmake --build /tmp/nerve-ssh-build --target nerve_ssh_smoke --parallel
/tmp/nerve-ssh-build/nerve_ssh_smoke 主机 端口 用户 SHA256:指纹 私钥文件
/tmp/nerve-ssh-build/nerve_ssh_smoke 主机 端口 用户 SHA256:指纹 私钥文件 测试会话名
~~~

如测试私钥带口令，可通过 `NERVE_SMOKE_KEY_PASSPHRASE` 传入。联调覆盖首次指纹探测、错误指纹、私钥登录、UTF-8 交互、终端尺寸同步和已有会话附接。

## 运行 Daemon

在 WSL 或 Linux 操作。Node.js 需为 24.14 或更高版本。使用 `sessions` 和 `panes` 命令时，`zellij` 需在 `PATH` 中。联调使用 Zellij 0.46.0。本机通过 WSL Bash 运行时，可用 `export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"` 临时加入 Homebrew 安装的 Zellij。建议让 Daemon、Codex、OMP 和 Zellij 在同一 Linux 用户下运行。

~~~bash
cd /mnt/d/Huawei/Nerve/daemon
npm ci
npm test
npm start
~~~

在另一个终端执行：

~~~bash
cd /mnt/d/Huawei/Nerve/daemon
node dist/cli.js health
node dist/cli.js sessions
node dist/cli.js panes "你的会话名"
node dist/cli.js events        # 从游标 0 读取前 50 条
node dist/cli.js events 0 10   # 从游标 0 读取前 10 条
~~~

`NERVE_HOME` 默认为 `~/.nerve`，内含 `nerve.sock` 和 `events.sqlite`。如需自定义，在 Daemon 和 Agent 启动前设置同一个绝对路径。目录需位于 Linux 文件系统并由当前用户独占访问（`0700`）。正常停止时 Socket 会被清理。若强制终止后重启遇到 `EADDRINUSE`，确认没有 Daemon 监听后再删除残留的 `nerve.sock`。

### Codex

~~~bash
node dist/cli.js codex-config > /tmp/nerve-codex-hooks.json
~~~

将输出中的 Hook 按事件合并到 `$CODEX_HOME/hooks.json`（默认 `~/.codex/hooks.json`）或受信任项目的 `.codex/hooks.json`。保留现有配置，从 Zellij 窗格启动 Codex，再用 `/hooks` 查看并信任新增的命令。生成的命令含 Node 和 Daemon 的绝对路径，移动目录后可重新生成。 [Codex Hooks 文档](https://developers.openai.com/codex/hooks)

### OMP

从希望关联的 Zellij 窗格启动，将扩展路径替换为本机的绝对路径。

~~~bash
omp -e /mnt/d/Huawei/Nerve/daemon/adapters/omp/extension.ts
~~~

扩展通过 OMP 自己的加载器运行，并复用已经构建的 Daemon 模块。 [OMP 18.22.2 扩展文档](https://github.com/can1357/oh-my-pi/blob/v18.22.2/docs/extensions.md)

## 事件与查询

| 原生来源 | 原生事件 | Nerve v1 事件 |
| --- | --- | --- |
| Codex | `SessionStart` | `agent.session.started` |
| Codex | `UserPromptSubmit` | `agent.task.started` |
| Codex | `PermissionRequest` | `agent.permission.required` |
| Codex | `Stop` | `agent.turn.stopped` |
| Codex | `SessionEnd` | `agent.session.ended` |
| OMP | `session_start` | `agent.session.started` |
| OMP | `agent_start` | `agent.task.started` |
| OMP | `agent_end` | `agent.task.ended` |
| OMP | `session_shutdown` | `agent.session.ended` |

- 事件包含版本、事件 ID、来源、工作目录、时间、原生 Agent 会话 ID，以及来源提供的可选轮次 ID。SQLite 只保存定义的元数据。
- 会话和窗格从 Zellij 提供的 `ZELLIJ_SESSION_NAME`、`ZELLIJ_PANE_ID` 读取。在 Zellij 外运行时仍记录事件，会话关联可空。窗格 ID 属于对应的会话，会话改名后既有窗格里的环境变量可能仍为旧值。 [Zellij CLI 文档](https://zellij.dev/documentation/cli-actions)
- `Stop` 和 `agent_end` 各自表示轮次或循环结束，任务结果需要更具体的原生信号。适配器向本地 Socket 请求最多等待 750 毫秒，Daemon 不可用时事件可能丢失。
- 本地接口提供 `GET /v1/health`、`POST /v1/events` 和 `GET /v1/events?after=0&limit=50`。相同事件 ID 可幂等重试。查询使用稳定的 SQLite 写入序号翻页，客户端将 `nextCursor` 作为下次请求的 `after`。

## 推送通知

### Daemon 与 Gateway 联调

Push Gateway 与 Daemon 使用同一份 Node.js 构建产物，各自运行。先在 `daemon/` 运行 `npm ci` 和 `npm run build`。在两个进程的启动环境中设置同一个 `NERVE_GATEWAY_TOKEN`，可用 `openssl rand -hex 32` 生成。

在 Gateway 的终端运行以下命令。临时目录用于本地联调，通常部署时用 `~/.nerve-gateway` 或通过 `NERVE_GATEWAY_HOME` 指定私有目录（`0700`）。监听端口默认是 `8787`，可通过 `NERVE_GATEWAY_PORT` 设置。

~~~bash
NERVE_GATEWAY_HOME="$(mktemp -d)" npm run gateway
~~~

在 Daemon 的终端运行以下命令。Daemon 和 Agent 进程使用同一个 `NERVE_HOME`。跨主机时，在 Gateway 前部署 HTTPS 反向代理，把 `NERVE_GATEWAY_URL` 改成代理提供的通知地址。Gateway 本身监听 `127.0.0.1`。

~~~bash
export NERVE_HOME="$(mktemp -d)"
export NERVE_GATEWAY_URL=http://127.0.0.1:8787/v1/notifications
npm start
~~~

两个进程都开始监听后，在继承同一 `NERVE_HOME` 和 `NERVE_GATEWAY_TOKEN` 的终端发一条测试事件，并查询状态。

~~~bash
printf '%s\n' '{"hook_event_name":"Stop","session_id":"push-demo","cwd":"/tmp"}' | node dist/cli.js codex-hook
node dist/cli.js push-status
curl -fsS -H "Authorization: Bearer $NERVE_GATEWAY_TOKEN" http://127.0.0.1:8787/v1/status
~~~

- 启用推送后，新收到的 Codex `PermissionRequest`、`Stop` 和 OMP `agent_end` 会随事件一起入队。既有事件仍可查询；首次启用只收新事件。
- 通知协议仅发送主机 ID、事件 ID、Agent、事件类型和时间。Gateway 按主机 ID 和事件 ID 判重。临时网络故障会退避重试，进程重启会恢复待发送队列。
- `pending` 表示待投递或等待重试；Daemon 的 `sent` 表示 Gateway 确认已入库，Gateway 的 `sent` 表示 Huawei Push Kit 已接受请求。`failed` 表示协议拒绝或华为返回了不可自动恢复的错误，错误码可在对应进程日志查看。本地收件模式下，Gateway 中已接收的通知会保留为 `pending`。

### 接入 Huawei Push Kit

在华为 API Console 获取已开通 Push Kit 的项目服务账号 JSON，并准备同一 HarmonyOS 应用的设备 Push Token。将服务账号文件保存在仓库外，只在 Gateway 进程设置以下配置。 [华为服务账号鉴权](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/push-jwt-token-V5/) · [通知消息 V3](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/push-send-alert/)

| 环境变量 | 用途 |
| --- | --- |
| `NERVE_HUAWEI_SERVICE_ACCOUNT_FILE` | 服务账号 JSON 的本地路径 |
| `NERVE_HUAWEI_PUSH_TOKEN` | 接收通知的单台设备的 Push Token |
| `NERVE_HUAWEI_CATEGORY` | 默认 `WORK`，对应项目的工作事项提醒权益。可设为 `MARKETING`，适用华为的静默通知及频控规则 |
| `NERVE_HUAWEI_TEST_MESSAGE` | 设为 `1` 时使用华为的测试消息模式 |

1. 在 DevEco Studio 为与 AppGallery Connect 注册应用相同的包名启用 Push Kit，并更新调试签名后安装。Nerve 当前包名为 `com.example.nerve`。 [开通与调试签名](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/push-config-setting)
2. 在 Nerve 连接页点击「推送通知」，允许系统通知，再点「获取令牌」和「保存令牌到文件」。将文件从手机传到运行 Gateway 的电脑，在启动环境中从文件读取 `NERVE_HUAWEI_PUSH_TOKEN`。 [华为获取 Push Token 指南](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/push-get-token/)
3. 配置 Gateway 的两项华为凭据。比如在 WSL 用下面的命令从私有目录读取文件，再按前面的方式启动 Gateway。

~~~bash
export NERVE_HUAWEI_SERVICE_ACCOUNT_FILE="$HOME/.nerve-gateway/huawei-service-account.json"
export NERVE_HUAWEI_PUSH_TOKEN="$(cat "$HOME/.nerve-gateway/nerve-push-token.txt")"
export NERVE_HUAWEI_TEST_MESSAGE=1
npm run gateway
~~~

Gateway 开始投递其目录中待发送的通知。锁屏正文使用固定模板。点击通知只传入主机 ID 和事件 ID。 [华为通知字段](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/push-scenariozed-api-request-param/)

### 从通知打开 Zellij 会话

在触发通知的开发机（WSL 或 macOS）用运行 Daemon 的同一个系统用户将构建后的 `nerve` 加入 SSH 用户的 `PATH`，例如从本项目的 `daemon/` 运行 `npm run build && npm link`。若 Daemon 使用自定义 `NERVE_HOME`，让 SSH 的非交互命令也能读到该值。

点击通知后，在「通知关联会话」页面使用目标主机的 SSH 凭据，点「连接并打开会话」。Nerve 在校验 SSH 指纹及 Daemon 主机 ID 后按事件 ID 查找原会话。已在终端时可以手动点「查看通知」切换。会话已关闭或改名时，终端显示原因。

## 验收

在 WSL 的 `daemon/` 运行 `npm test`，验证字段映射、并发去重、输入大小、游标、推送事务、掉线重试、双方重启恢复以及 Huawei V3 的签名和响应解析。实机命令行联调使用真实 Codex 0.169.0、OMP 18.22.2 和 Zellij 0.46.0，模型回复由隔离的本地测试服务提供。上表 9 种原生事件均在实际运行中写入 SQLite，其中权限事件发生在 Codex 发出原生审批请求时。通过 `events` 查到各个 Agent 的原生事件后，可用 `panes` 核对 `zellij.paneId`。

推送联调期间先保持 Gateway 离线。三种提醒由真实 Agent 事件触发，并在 Gateway 启动后各入库一次。Huawei V3 的签名和响应处理由本地测试覆盖。Mate 90 Pro1 已验证模拟点击后经 SSH 进入 WSL 上的已有 Zellij 会话。

使用带 Push Kit 权益的签名包，在 HarmonyOS 7.0.0 的 Mate 90 Pro 模拟器取得真实设备令牌。Gateway 发送的测试通知在锁屏期间到达，亮屏后可在通知中心查看，点击打开 Nerve 的关联会话入口。本次通知被归为静默类，锁屏页面未直接显示通知。真机接收仍待验证。
