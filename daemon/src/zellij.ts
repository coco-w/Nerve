import { execFile, spawn } from 'node:child_process';
import { once } from 'node:events';
import { promisify } from 'node:util';
import { isRecord } from './agent.js';

const exec = promisify(execFile);

export class ZellijSessionUnavailable extends Error {
  constructor() {
    super('Zellij 会话已关闭或改名。');
  }
}

function callZellij(args: string[]) {
  // 参数直接交给 Zellij CLI，避免将会话名拼到 shell 命令中。
  return exec('zellij', args, { timeout: 3000, maxBuffer: 4 * 1024 * 1024 });
}

export async function listSessions(): Promise<string[]> {
  try {
    const { stdout } = await callZellij(['list-sessions', '--short', '--no-formatting']);
    return stdout.split(/\r?\n/).filter(Boolean);
  } catch (error) {
    // Zellij 0.46 无会话时退出码为 1，其他错误保持可见。
    if (isRecord(error) && error.code === 1 && typeof error.stderr === 'string'
        && error.stderr.trim() === 'No active zellij sessions found.') {
      return [];
    }
    throw error;
  }
}

export async function listPanes(session: string) {
  const { stdout } = await callZellij(['--session=' + session, 'action', 'list-panes', '--json']);
  if (!stdout.trim()) throw new Error('Zellij 未返回窗格数据，请先 attach 到该会话再重试');
  const panes: unknown = JSON.parse(stdout);
  if (!Array.isArray(panes)) throw new Error('Zellij 未返回 Pane 列表');

  return panes.map(pane => {
    if (!isRecord(pane) || typeof pane.id !== 'number' || !Number.isSafeInteger(pane.id)
        || pane.id < 0 || typeof pane.is_plugin !== 'boolean' || typeof pane.title !== 'string') {
      throw new Error('Zellij 返回了无效的 Pane 数据');
    }
    return { paneId: (pane.is_plugin ? 'plugin_' : 'terminal_') + pane.id, title: pane.title };
  });
}

export async function attachExistingSession(session: string): Promise<number> {
  if (session.startsWith('-') || session === 'options' || session === 'help') {
    throw new Error('该会话名与 Zellij 命令参数冲突，请手动进入会话。');
  }
  // 先核对完整名称和实际窗格，避免匹配同名前缀或复活已退出的会话。
  if (!(await listSessions()).includes(session)) throw new ZellijSessionUnavailable();
  try {
    await listPanes(session);
  } catch (error) {
    // 0.46 的简短列表包含可恢复的旧会话，实际窗格查询能识别已退出的目标。
    if (isRecord(error) && typeof error.stderr === 'string') {
      const detail = error.stderr.trim();
      if (detail === 'There is no active session!' || detail.startsWith("Session '" + session + "' not found.")) {
        throw new ZellijSessionUnavailable();
      }
    }
    throw error;
  }
  // 把 SSH 分配的终端交给 Zellij，断开手机时保留远端会话。
  const child = spawn('zellij', ['attach', session, 'options', '--on-force-close', 'detach'], { stdio: 'inherit' });
  const [code] = await once(child, 'exit') as [number | null, NodeJS.Signals | null];
  return code ?? 1;
}
