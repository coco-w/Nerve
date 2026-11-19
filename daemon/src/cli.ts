#!/usr/bin/env node
import { getAsset, isSea } from 'node:sea';
import { fileURLToPath } from 'node:url';
import { codexEvents, fromCodexHook, isRecord, parseAgentEvent, uuidPattern } from './agent.js';
import { nerveHome, requestJson } from './local-http.js';
import { notificationFromEvent } from './notification.js';
import { pushTargetFromEnv } from './push-client.js';
import { attachExistingSession, listPanes, listSessions, ZellijSessionUnavailable } from './zellij.js';

// SSH 客户端用此退出状态显示通知会话已关闭，即使远端终端未收到错误正文。
const SESSION_UNAVAILABLE_EXIT_STATUS = 20;

function printJson(value: unknown) {
  process.stdout.write(JSON.stringify(value, null, 2) + '\n');
}

function shellQuote(value: string) {
  return "'" + value.replaceAll("'", "'\\''") + "'";
}

function codexHookConfig() {
  // 独立版直接调用可执行文件，源码版使用 Node 和脚本的绝对路径。
  const launcher = isSea() ? [process.execPath] : [process.execPath, fileURLToPath(import.meta.url)];
  const command = [...launcher, 'codex-hook'].map(shellQuote).join(' ');
  return {
    hooks: Object.fromEntries(Object.keys(codexEvents).map(event => [
      event, [{ hooks: [{ type: 'command', command, timeout: 3 }] }],
    ])),
  };
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
      const { startDaemon } = await import('./server.js');
      const { server, socketPath } = await startDaemon(nerveHome(), pushTargetFromEnv(process.env));
      const stop = () => server.close();
      process.once('SIGINT', stop);
      process.once('SIGTERM', stop);
      console.error('[Nerve] 正在监听 ' + socketPath);
      break;
    }
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
      printJson(codexHookConfig());
      break;
    case 'codex-hook':
      await codexHook();
      break;
    case 'omp-extension':
      // 导出与当前可执行文件同版本的独立 OMP 扩展。
      if (!isSea()) throw new Error('源码版扩展位于 daemon/adapters/omp/extension.ts');
      process.stdout.write(getAsset('omp-extension.mjs', 'utf8'));
      break;
    case undefined:
    case '--help':
      console.log('nerve start | health | push-status | events [after] [limit] | sessions | panes <session> | codex-config'
        + ' | attach-event <host-id> <event-id>' + (isSea() ? ' | omp-extension' : ''));
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
