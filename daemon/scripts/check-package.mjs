import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { basename, join, resolve } from 'node:path';
import { setTimeout as wait } from 'node:timers/promises';
import { pathToFileURL } from 'node:url';

const archive = resolve(process.argv[2]);
// 保持 Socket 路径简短，兼容 macOS 的 Unix Socket 路径长度。
const workspace = await mkdtemp('/tmp/nerve-package-');
const installDir = join(workspace, 'nerve bin');
const instance = join(workspace, 'instance');
const env = { ...process.env, PATH: installDir, NERVE_HOME: instance };
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
  execFileSync(installer, { env: { ...process.env, NERVE_INSTALL_DIR: installDir } });
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

  // 执行生成的 Hook，确认引用的是已安装的 nerve，且空格路径可用。
  const hook = JSON.parse(run('codex-config')).hooks.Stop[0].hooks[0].command;
  assert.equal(execFileSync('/bin/sh', ['-c', hook], {
    env,
    encoding: 'utf8',
    input: JSON.stringify({ hook_event_name: 'Stop', session_id: 'package-codex', cwd: workspace }),
    timeout: 3000,
  }).trim(), '{}');

  // 从二进制导出扩展，在归档外加载并走现有 Unix Socket 适配器。
  const extensionPath = join(workspace, 'omp-extension.mjs');
  await writeFile(extensionPath, run('omp-extension'));
  process.env.NERVE_HOME = instance;
  const { default: extension } = await import(pathToFileURL(extensionPath).href);
  const callbacks = new Map();
  extension({ on: (name, callback) => callbacks.set(name, callback) });
  await callbacks.get('session_start')({}, {
    cwd: workspace,
    sessionManager: { getSessionId: () => 'package-omp' },
  });
  const { events } = JSON.parse(run('events'));
  assert.deepEqual(events.map(event => event.agent), ['codex', 'omp']);
  console.log('安装包已通过独立启动、SQLite 事件入库和 Codex／OMP 集成测试');
} finally {
  daemon?.kill('SIGTERM');
  await closed;
  await rm(workspace, { recursive: true, force: true });
}
