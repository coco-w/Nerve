import assert from 'node:assert/strict';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { basename, join, resolve } from 'node:path';
import { setTimeout as wait } from 'node:timers/promises';
import { pathToFileURL } from 'node:url';

const archive = resolve(process.argv[2]);
// 保持 Socket 路径简短，兼容 macOS 的 Unix Socket 路径长度。
const workspace = await mkdtemp('/tmp/nerve-package-');
const installDir = join(workspace, 'nerve bin');
const instance = join(workspace, 'instance');
const home = join(workspace, 'home');
const codexHome = join(home, 'codex config');
const ompExtensions = join(home, 'omp config', 'extensions');
const agentBin = join(workspace, 'agents');
const env = { ...process.env, PATH: installDir, HOME: home, CODEX_HOME: codexHome, NERVE_HOME: instance };
delete env.NERVE_GATEWAY_URL;
delete env.NERVE_GATEWAY_TOKEN;
delete env.NODE_OPTIONS;
const nerve = join(installDir, 'nerve');
const run = (...args) => execFileSync(nerve, args, {
  cwd: workspace, env, encoding: 'utf8', timeout: 3000, stdio: 'pipe',
});
let daemon;
let closed;

try {
  execFileSync('tar', ['-xzf', archive, '-C', workspace]);
  const installer = join(workspace, basename(archive, '.tar.gz'), 'install.sh');
  const installEnv = { ...env, PATH: `${agentBin}:/usr/bin:/bin`, NERVE_INSTALL_DIR: installDir };
  const install = (...args) => execFileSync(installer, args, { cwd: workspace, env: installEnv, encoding: 'utf8' });
  await mkdir(codexHome, { recursive: true });
  await mkdir(ompExtensions, { recursive: true });
  await mkdir(agentBin);
  const hooksFile = join(codexHome, 'hooks.json');
  const extensionPath = join(ompExtensions, 'nerve-daemon.js');
  const otherExtension = join(ompExtensions, 'existing.js');
  const otherExtensionContent = 'export default () => {};\n';
  await writeFile(otherExtension, otherExtensionContent);
  // 用隔离的 CLI 探针模拟两端配置查询，真实事件适配链路在下方验证。
  await writeFile(join(agentBin, 'codex'), '#!/bin/sh\nprintf "codex-cli 0.169.0\\n"\n', { mode: 0o700 });
  await writeFile(join(agentBin, 'omp'), '#!/bin/sh\n[ "$1 $2" = "config path" ] || exit 1\nprintf "%s\\n" "$PI_CODING_AGENT_DIR"\n',
    { mode: 0o700 });
  installEnv.PI_CODING_AGENT_DIR = join(ompExtensions, '..');
  install('--no-agents');
  await assert.rejects(readFile(hooksFile), { code: 'ENOENT' });
  await assert.rejects(readFile(extensionPath), { code: 'ENOENT' });
  // 缺少 Agent 时只提示，安装仍可使用。
  assert.match(run('setup-agents'), /未找到 Codex[\s\S]*未找到 OMP/);

  const { hooks: generated } = JSON.parse(run('codex-config'));
  const userGroup = { matcher: '*', hooks: [{ type: 'command', command: 'echo existing' }] };
  const original = { description: 'existing config', hooks: { Stop: [userGroup, ...generated.Stop], PreToolUse: [userGroup] } };
  await writeFile(hooksFile, JSON.stringify(original));
  assert.match(install(), /已配置 Codex[\s\S]*已配置 OMP/);
  const merged = await readFile(hooksFile, 'utf8');
  const loaded = JSON.parse(merged);
  assert.deepEqual(loaded, { ...original, hooks: { ...generated, ...original.hooks } });
  const extension = await readFile(extensionPath, 'utf8');
  assert.ok(extension.endsWith(run('omp-extension')));
  assert.equal(await readFile(otherExtension, 'utf8'), otherExtensionContent);
  install();
  assert.equal(await readFile(hooksFile, 'utf8'), merged);
  assert.equal(await readFile(extensionPath, 'utf8'), extension);

  // 无效 JSON 必须保留原样，另一种 Agent 仍然可以接入。
  await writeFile(hooksFile, '{ broken');
  await rm(extensionPath);
  const partial = spawnSync(nerve, ['setup-agents'], { cwd: workspace, env: installEnv, encoding: 'utf8' });
  assert.equal(partial.status, 1);
  assert.match(partial.stderr, /无法解析 Hook JSON/);
  assert.equal(await readFile(hooksFile, 'utf8'), '{ broken');
  assert.equal(await readFile(extensionPath, 'utf8'), extension);
  await writeFile(hooksFile, merged);

  await writeFile(extensionPath, otherExtensionContent);
  const collision = spawnSync(nerve, ['setup-agents'], { cwd: workspace, env: installEnv, encoding: 'utf8' });
  assert.equal(collision.status, 1);
  assert.match(collision.stderr, /扩展文件已被占用/);
  assert.equal(await readFile(extensionPath, 'utf8'), otherExtensionContent);
  await writeFile(extensionPath, extension);

  // 安装目录外运行，PATH 中没有 Node.js 或 npm。
  assert.match(run('--help'), /nerve start/);
  daemon = spawn(nerve, ['start'], { cwd: workspace, env, stdio: ['ignore', 'ignore', 'pipe'] });
  closed = new Promise(resolveClose => daemon.once('close', resolveClose));
  let startupError = '';
  daemon.stderr.setEncoding('utf8').on('data', message => { startupError += message; });
  daemon.on('error', error => { startupError += String(error); });
  let ready = false;
  const deadline = Date.now() + 5000;
  while (!ready && Date.now() < deadline && daemon.exitCode === null) {
    try {
      ready = JSON.parse(run('health')).status === 'ok';
    } catch {
      await wait(100);
    }
  }
  assert.ok(ready, '独立版 Daemon 启动失败\n' + startupError);

  // 执行已自动注册的 Hook，确认命令引用已安装的 nerve，且空格路径可用。
  const hook = loaded.hooks.Stop[1].hooks[0].command;
  assert.equal(execFileSync('/bin/sh', ['-c', hook], {
    env,
    encoding: 'utf8',
    input: JSON.stringify({ hook_event_name: 'Stop', session_id: 'package-codex', cwd: workspace }),
    timeout: 3000,
  }).trim(), '{}');

  // 加载安装脚本注册的扩展，并验证它通过 Unix Socket 上报事件。
  process.env.NERVE_HOME = instance;
  const { default: loadExtension } = await import(pathToFileURL(extensionPath).href);
  const callbacks = new Map();
  loadExtension({ on: (name, callback) => callbacks.set(name, callback) });
  await callbacks.get('session_start')({}, {
    cwd: workspace,
    sessionManager: { getSessionId: () => 'package-omp' },
  });
  const { events } = JSON.parse(run('events'));
  assert.deepEqual(events.map(event => event.agent), ['codex', 'omp']);
  console.log('安装包已通过 Agent 自动接入、独立启动和 SQLite 事件入库测试');
} finally {
  daemon?.kill('SIGTERM');
  await closed;
  await rm(workspace, { recursive: true, force: true });
}
