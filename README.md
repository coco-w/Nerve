# Nerve

Nerve 是面向 HarmonyOS 的远程开发工具。手机将通过 SSH/Mosh 直连开发机的 Zellij 会话。主机上的 Nerve Daemon 采集 Codex Hooks 和 Oh My Pi（OMP）扩展事件。独立的 Push Gateway 将把需要提醒的事件交给 Huawei Push Kit。

## 当前进度

- 根目录是现有的 DevEco Studio 单模块工程。入口在 `entry/`，当前能构建未签名 HAP。
- `daemon/` 是 Node.js + TypeScript PoC。在同一系统用户下通过 Unix Socket 采集事件，写入 SQLite，并提供事件查询和 Zellij 会话、窗格列表。
- 下一阶段先用鸿蒙真机验证 SSH PTY、终端尺寸同步和 `zellij attach`。随后验证 Mosh，以及通过独立 Gateway 发送系统通知、锁屏接收和点击后回到会话。Gateway 将使用最小通知字段，待发送记录应在本地持久化后再异步投递。

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

## 验收

在 WSL 运行 `npm test`，验证字段映射、并发去重、输入大小、游标和 SQLite 重启恢复。实机命令行联调使用真实 Codex 0.169.0、OMP 18.22.2 和 Zellij 0.46.0，模型回复由隔离的本地测试服务提供。上表 9 种原生事件均在实际运行中写入 SQLite，其中权限事件发生在 Codex 发出原生审批请求时。通过 `events` 查到各个 Agent 的原生事件后，可用 `panes` 核对 `zellij.paneId`。
