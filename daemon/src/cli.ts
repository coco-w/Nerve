#!/usr/bin/env node
import { fileURLToPath } from 'node:url';
import { codexEvents, fromCodexHook } from './agent.js';
import { nerveHome, requestJson } from './local-http.js';
import { pushTargetFromEnv } from './push-client.js';
import { listPanes, listSessions } from './zellij.js';

function printJson(value: unknown) {
  process.stdout.write(JSON.stringify(value, null, 2) + '\n');
}

function shellQuote(value: string) {
  return "'" + value.replaceAll("'", "'\\''") + "'";
}

function codexHookConfig() {
  // 使用构建时命令所在的绝对路径，避免 Agent 工作目录改变后找不到脚本。
  const command = [process.execPath, fileURLToPath(import.meta.url), 'codex-hook'].map(shellQuote).join(' ');
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
    case 'codex-config':
      printJson(codexHookConfig());
      break;
    case 'codex-hook':
      await codexHook();
      break;
    case undefined:
    case '--help':
      console.log('nerve start | health | push-status | events [after] [limit] | sessions | panes <session> | codex-config');
      break;
    default:
      throw new Error('未知命令，请运行 nerve --help');
  }
}

main(process.argv.slice(2)).catch(error => {
  const message = error instanceof Error ? error.message : String(error);
  console.error('[Nerve] ' + message);
  process.exitCode = 1;
});
