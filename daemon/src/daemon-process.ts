import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { closeSync, constants, fstatSync, openSync } from 'node:fs';
import { join } from 'node:path';
import { isRecord } from './agent.js';
import { nerveHome, requestJson } from './local-http.js';
import { ensurePrivateDirectory } from './private-directory.js';
import { p2pHostFromEnv } from './p2p/config.js';
import { pushTargetFromEnv } from './push-client.js';

const startupTimeoutMs = 8000;
export const daemonReadyMessage = 'nerve-ready';

function daemonUnavailable(error: unknown) {
  return error instanceof Error && 'code' in error && (error.code === 'ENOENT' || error.code === 'ECONNREFUSED');
}

async function daemonIsRunning() {
  try {
    const response = await requestJson('/v1/health');
    if (isRecord(response) && response.status === 'ok') return true;
    throw new Error('本地 Daemon 健康检查返回异常');
  } catch (error) {
    if (daemonUnavailable(error)) return false;
    throw error;
  }
}

function spawnDaemon(args: string[], logPath: string) {
  // 日志留在私有数据目录，只追加普通文件。
  const log = openSync(logPath, constants.O_CREAT | constants.O_WRONLY | constants.O_APPEND
    | constants.O_NOFOLLOW | constants.O_NONBLOCK, 0o600);
  try {
    if (!fstatSync(log).isFile()) throw new Error('Daemon 日志路径必须是普通文件 ' + logPath);
    // 新进程脱离启动终端，继承当前 Gateway 配置并将输出写入日志。
    return spawn(process.execPath, args, { detached: true, stdio: ['ignore', log, log, 'ipc'] });
  } finally {
    closeSync(log);
  }
}

export async function startBackgroundDaemon(args: string[]) {
  if (process.platform === 'win32') throw new Error('请在 WSL、Linux 或 macOS 中启动 Daemon');
  const directory = nerveHome();
  ensurePrivateDirectory(directory, 'NERVE_HOME');
  if (await daemonIsRunning()) {
    console.log('Nerve Daemon 已在运行');
    return;
  }
  // 启动前报告配置错误，避免只在后台日志中看到原因。
  pushTargetFromEnv(process.env);
  p2pHostFromEnv(process.env);
  const logPath = join(directory, 'daemon.log');
  const child = spawnDaemon(args, logPath);
  try {
    // 等本次启动的进程确认就绪或退出，再放开控制台和通讯通道。
    const signal = AbortSignal.timeout(startupTimeoutMs);
    const [result] = await Promise.race([once(child, 'message', { signal }), once(child, 'exit', { signal })]);
    if (result === daemonReadyMessage) {
      console.log('Nerve Daemon 正在后台运行。日志 ' + logPath);
      return;
    }
    // 并发启动时由 Unix Socket 保证只有一个监听者。
    if (await daemonIsRunning()) {
      console.log('Nerve Daemon 已在运行');
      return;
    }
    throw new Error('Daemon 启动失败，请查看日志 ' + logPath);
  } catch (error) {
    if (child.pid && child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
    if (error instanceof Error && error.name === 'AbortError') {
      throw new Error('Daemon 启动超时，请查看日志 ' + logPath, { cause: error });
    }
    throw error;
  } finally {
    if (child.connected) child.disconnect();
    child.unref();
  }
}

export async function stopRunningDaemon() {
  try {
    const response = await requestJson('/v1/shutdown', {});
    if (!isRecord(response) || response.status !== 'stopping') throw new Error('Daemon 停止确认返回异常');
    console.log('Nerve Daemon 已停止');
  } catch (error) {
    if (daemonUnavailable(error)) {
      console.log('Nerve Daemon 当前未运行');
      return;
    }
    if (error instanceof Error && error.message === 'Daemon 返回 HTTP 404') {
      throw new Error('正在运行的是较早版本，请在原启动终端按 Ctrl+C 停止');
    }
    throw error;
  }
}
