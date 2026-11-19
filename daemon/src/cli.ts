#!/usr/bin/env node
import { getAsset, isSea } from 'node:sea';
import { fileURLToPath } from 'node:url';
import { fromCodexHook, isRecord, parseAgentEvent, uuidPattern } from './agent.js';
import { daemonReadyMessage, startBackgroundDaemon, stopRunningDaemon } from './daemon-process.js';
import { nerveHome, requestJson } from './local-http.js';
import { notificationFromEvent } from './notification.js';
import { pushTargetFromEnv } from './push-client.js';
import { codexHookGroups, setupAgents } from './setup-agents.js';
import { attachExistingSession, listPanes, listSessions, ZellijSessionUnavailable } from './zellij.js';

// SSH 客户端用此退出状态显示通知会话已关闭，即使远端终端未收到错误正文。
const SESSION_UNAVAILABLE_EXIT_STATUS = 20;

function printJson(value: unknown) {
  process.stdout.write(JSON.stringify(value, null, 2) + '\n');
}

function shellQuote(value: string) {
  return "'" + value.replaceAll("'", "'\\''") + "'";
}

function nerveArgs(...args: string[]) {
  // 独立版直接传入子命令，源码版需要向 Node 传入脚本路径。
  return isSea() ? args : [fileURLToPath(import.meta.url), ...args];
}

function codexHookCommand() {
  return [process.execPath, ...nerveArgs('codex-hook')].map(shellQuote).join(' ');
}

async function codexHook() {
  try {
    // Codex 从 stdin 提供原生 JSON，仅读取协议需要的字段。
    const buffers: Buffer[] = [];
    let bytes = 0;
    for await (const chunk of process.stdin) {
      bytes += chunk.length;
      if (bytes > 1024 * 1024) throw new Error('Hook 输入过长');
      buffers.push(chunk);
    }
    const event = fromCodexHook(JSON.parse(Buffer.concat(buffers).toString('utf8')));
    if (event) await requestJson('/v1/events', event, 750);
  } catch {
    process.stderr.write('[Nerve] Codex 事件未送达本地 Daemon\n');
  }

  // 空的 JSON 结果适用于 Stop 等 JSON Hook，保留 Codex 的默认行为。
  process.stdout.write('{}\n');
}

async function attachEvent(hostId: string | undefined, eventId: string | undefined) {
  if (!hostId || !uuidPattern.test(hostId) || !eventId || !uuidPattern.test(eventId)) {
    throw new Error('用法为 nerve attach-event <host-id> <event-id>');
  }
  // 先验证本机标识，避免用户选错开发机时打开同名会话。
  const health = await requestJson('/v1/health');
  if (!isRecord(health) || health.hostId !== hostId) throw new Error('此通知来自另一台开发机。');
  let response: unknown;
  try {
    response = await requestJson('/v1/events/' + eventId);
  } catch (error) {
    if (error instanceof Error && error.message === 'Daemon 返回 HTTP 404') {
      throw new Error('当前 Daemon 找不到此通知对应的事件。');
    }
    throw error;
  }
  const event = parseAgentEvent(response);
  if (!isRecord(response) || response.hostId !== hostId || !event || event.eventId !== eventId
      || !notificationFromEvent(hostId, event) || !event.zellij) {
    throw new Error('此通知没有关联的 Zellij 会话。');
  }
  process.exitCode = await attachExistingSession(event.zellij.sessionName);
}

async function main([command, arg, limit]: string[]) {
  switch (command) {
    case 'start': {
      if (arg === undefined) {
        await startBackgroundDaemon(nerveArgs('start', '--foreground'));
        break;
      }
      if (arg !== '--foreground' || limit !== undefined) throw new Error('用法为 nerve start [--foreground]');
      const { startDaemon } = await import('./server.js');
      const { server, socketPath } = await startDaemon(nerveHome(), pushTargetFromEnv(process.env));
      const stop = () => server.close();
      process.once('SIGINT', stop);
      process.once('SIGTERM', stop);
      process.once('SIGHUP', stop);
      console.error('[Nerve] 正在监听 ' + socketPath);
      // Unix Socket 就绪后应答启动命令。启动终端提前退出时仍可提供服务。
      if (process.connected) process.send?.(daemonReadyMessage, () => {});
      break;
    }
    case 'stop':
      if (arg !== undefined) throw new Error('用法为 nerve stop');
      await stopRunningDaemon();
      break;
    case 'health':
      printJson(await requestJson('/v1/health'));
      break;
    case 'push-status':
      printJson(await requestJson('/v1/push/status'));
      break;
    case 'events': {
      const params = new URLSearchParams({ after: arg ?? '0', limit: limit ?? '50' });
      printJson(await requestJson('/v1/events?' + params));
      break;
    }
    case 'sessions':
      printJson(await listSessions());
      break;
    case 'panes':
      if (!arg) throw new Error('用法为 nerve panes <session>');
      printJson(await listPanes(arg));
      break;
    case 'attach-event':
      await attachEvent(arg, limit);
      break;
    case 'codex-config':
      printJson({ hooks: codexHookGroups(codexHookCommand()) });
      break;
    case 'codex-hook':
      await codexHook();
      break;
    case 'omp-extension':
      // 导出与当前可执行文件同版本的独立 OMP 扩展。
      if (!isSea()) throw new Error('源码版扩展位于 daemon/adapters/omp/extension.ts');
      process.stdout.write(getAsset('omp-extension.mjs', 'utf8'));
      break;
    case 'setup-agents':
      if (!isSea()) throw new Error('请使用安装包运行 nerve setup-agents，源码版的接入方式见 README。');
      if (arg) throw new Error('用法为 nerve setup-agents');
      if (!setupAgents(codexHookCommand(), getAsset('omp-extension.mjs', 'utf8'))) process.exitCode = 1;
      break;
    case undefined:
    case '--help':
      console.log('nerve start [--foreground] | stop | health | push-status | events [after] [limit] | sessions | panes <session> | codex-config'
        + ' | attach-event <host-id> <event-id>' + (isSea() ? ' | setup-agents | omp-extension' : ''));
      break;
    default:
      throw new Error('未知命令，请运行 nerve --help');
  }
}

main(process.argv.slice(2)).catch(error => {
  const message = error instanceof Error ? error.message : String(error);
  console.error('[Nerve] ' + message);
  process.exitCode = error instanceof ZellijSessionUnavailable ? SESSION_UNAVAILABLE_EXIT_STATUS : 1;
});
