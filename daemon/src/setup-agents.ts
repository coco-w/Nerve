import { spawnSync } from 'node:child_process';
import { linkSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { codexEvents, isRecord } from './agent.js';

// 仅更新安装程序自己写入的 OMP 扩展，保留用户同名文件。
const managedOmpHeader = '// 此扩展由 Nerve Daemon 安装程序管理。\n';

export function codexHookGroups(command: string) {
  // 自动注册与手动导出使用同一套已支持的 Codex 事件。
  return Object.fromEntries(Object.keys(codexEvents).map(event => [
    // 提问 Hook 使用精确匹配，避免每一次普通工具执行都启动适配器。
    event, [{ ...(event === 'PreToolUse' ? { matcher: '^request_user_input$' } : {}),
      hooks: [{ type: 'command', command, timeout: 3 }] }],
  ]));
}

function readConfigFile(path: string) {
  const stat = lstatSync(path, { throwIfNoEntry: false });
  if (!stat) return undefined;
  if (!stat.isFile()) throw new Error('配置路径必须是普通文件 ' + path);
  return { content: readFileSync(path, 'utf8'), mode: stat.mode & 0o777 };
}

function writeConfigFile(path: string, previous: ReturnType<typeof readConfigFile>, content: string) {
  if (previous?.content === content) return;
  const directory = dirname(path);
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const staging = mkdtempSync(join(directory, '.nerve-setup-'));
  const candidate = join(staging, 'config');
  try {
    writeFileSync(candidate, content, { mode: previous?.mode ?? 0o600 });
    if (previous) {
      // 写入同目录的临时文件，提交前检查用户是否已修改配置。
      if (readConfigFile(path)?.content !== previous.content) {
        throw new Error('配置已被其他进程修改，请重试 ' + path);
      }
      renameSync(candidate, path);
    } else {
      // 首次注册以独占方式创建，避免覆盖同时创建的配置。
      linkSync(candidate, path);
    }
  } finally {
    rmSync(staging, { recursive: true, force: true });
  }
}

function readAgentOutput(agent: string, ...args: string[]) {
  const result = spawnSync(agent, args, { encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'] });
  if (result.error && 'code' in result.error && result.error.code === 'ENOENT') return undefined;
  if (result.error || result.status !== 0) throw new Error('无法运行 ' + [agent, ...args].join(' '));
  return result.stdout.replace(/\r?\n$/, '');
}

function setupCodex(command: string) {
  if (readAgentOutput('codex', '--version') === undefined) return undefined;
  // CODEX_HOME 与 Codex CLI 使用同一用户目录，默认写入 ~/.codex/hooks.json。
  const path = join(resolve(process.env.CODEX_HOME || join(homedir(), '.codex')), 'hooks.json');
  const previous = readConfigFile(path);
  let config: unknown;
  try {
    config = JSON.parse(previous?.content ?? '{}');
  } catch {
    throw new Error('无法解析 Hook JSON ' + path);
  }
  if (!isRecord(config) || (config.hooks !== undefined && !isRecord(config.hooks))) {
    throw new Error('无法合并 Hook 配置 ' + path);
  }
  const hooks = config.hooks ?? {};
  let changed = false;
  for (const [event, newGroups] of Object.entries(codexHookGroups(command))) {
    const groups = hooks[event] === undefined ? [] : hooks[event];
    if (!Array.isArray(groups) || groups.some(group => !isRecord(group) || !Array.isArray(group.hooks))) {
      throw new Error('无法合并 ' + event + ' Hook ' + path);
    }
    // 保留已有分组和索引。旧版手动添加的相同命令可直接沿用。
    if (groups.some(group => group.hooks.some((hook: unknown) =>
      isRecord(hook) && hook.type === 'command' && hook.command === command))) continue;
    hooks[event] = [...groups, ...newGroups];
    changed = true;
  }
  if (changed) writeConfigFile(path, previous, JSON.stringify({ ...config, hooks }, null, 2) + '\n');
  return path;
}

function setupOmp(extension: string) {
  // OMP 自己解析用户目录、PI_CODING_AGENT_DIR 和当前环境选择的 profile。
  const directory = readAgentOutput('omp', 'config', 'path');
  if (directory === undefined) return undefined;
  if (!isAbsolute(directory) || /[\r\n]/.test(directory)) throw new Error('OMP 返回了无效的配置目录');
  // 自动发现支持 .js 和 .ts。导出的 .mjs 则用于已有的手动加载方式。
  const path = join(directory, 'extensions', 'nerve-daemon.js');
  const previous = readConfigFile(path);
  if (previous && !previous.content.startsWith(managedOmpHeader)) throw new Error('扩展文件已被占用 ' + path);
  writeConfigFile(path, previous, managedOmpHeader + extension);
  return path;
}

export function setupAgents(command: string, extension: string) {
  const agents = [
    { name: 'Codex', setup: () => setupCodex(command), hint: '在 Codex 中打开 /hooks 并信任 Nerve Hook。' },
    { name: 'OMP', setup: () => setupOmp(extension), hint: '下次正常启动 omp 时会自动加载扩展。' },
  ];
  let success = true;
  for (const { name, setup, hint } of agents) {
    try {
      const path = setup();
      console.log(path ? `已配置 ${name} ${path}\n${hint}` : `未找到 ${name}。安装后可运行 nerve setup-agents。`);
    } catch (error) {
      // 一种 Agent 遇到冲突时，另一种仍可完成配置。
      success = false;
      const message = error instanceof Error ? error.message : String(error);
      console.error(`[Nerve] ${name} 接入失败。${message}`);
    }
  }
  return success;
}
