import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { isRecord } from './agent.js';

const exec = promisify(execFile);

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
