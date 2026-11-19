import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { mkdtemp, readdir, rm, stat } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { basename, join, resolve } from 'node:path';
import { setTimeout as wait } from 'node:timers/promises';
import { receiptHeader, signNotification, signReceipt } from '../dist/gateway-auth.js';

const archive = resolve(process.argv[2]);
const workspace = await mkdtemp(join(tmpdir(), 'nerve-gateway-package-'));
const installDir = join(workspace, 'gateway bin');
const directory = join(workspace, 'instance');
const binary = join(installDir, 'nerve-gateway');
const token = 'test-gateway-' + randomUUID();
let gateway;
let closed;

try {
  execFileSync('tar', ['-xzf', archive, '-C', workspace]);
  const installer = join(workspace, basename(archive, '.tar.gz'), 'install.sh');
  execFileSync(installer, { env: { ...process.env, NERVE_INSTALL_DIR: installDir } });
  assert.deepEqual(await readdir(installDir), ['nerve-gateway']);

  const reservation = createServer().listen(0, '127.0.0.1');
  await once(reservation, 'listening');
  const { port } = reservation.address();
  await new Promise(resolveClose => reservation.close(resolveClose));
  // 只给安装包进程本机配置，PATH 中没有外部 Node 或 npm，也无需华为凭据。
  const env = {
    HOME: workspace, PATH: installDir, NERVE_GATEWAY_HOME: directory,
    NERVE_GATEWAY_PORT: String(port), NERVE_GATEWAY_TOKEN: token,
  };
  assert.match(execFileSync(binary, ['--help'], { env, encoding: 'utf8' }), /nerve-gateway/);
  gateway = spawn(binary, ['start'], { cwd: workspace, env, stdio: ['ignore', 'ignore', 'pipe'] });
  closed = new Promise(resolveClose => gateway.once('close', resolveClose));
  let startupLog = '';
  gateway.stderr.setEncoding('utf8').on('data', chunk => { startupLog += chunk; });
  gateway.on('error', error => { startupLog += String(error); });

  const address = `http://127.0.0.1:${port}`;
  async function readStatus() {
    const response = await fetch(address + '/v1/status', {
      headers: { authorization: 'Bearer ' + token, connection: 'close' }, signal: AbortSignal.timeout(1000),
    });
    assert.equal(response.status, 200);
    return response.json();
  }
  let status;
  const deadline = Date.now() + 5000;
  while (!status && Date.now() < deadline && gateway.exitCode === null) {
    try {
      status = await readStatus();
    } catch {
      await wait(75);
    }
  }
  assert.ok(status, '独立 Gateway 启动失败\n' + startupLog);
  assert.equal(status.deliveryEnabled, false);
  assert.equal(status.pending, 0);

  // 发出 Daemon 同款签名通知和一次重试，核对入库回执与队列去重。
  const body = JSON.stringify({
    schemaVersion: 1, hostId: randomUUID(), eventId: randomUUID(),
    agent: 'codex', eventType: 'agent.turn.stopped', occurredAt: Date.now(),
  });
  for (const expectedStatus of [202, 200]) {
    const authorization = signNotification(token, body);
    const response = await fetch(address + '/v1/notifications', {
      method: 'POST', body, signal: AbortSignal.timeout(2000),
      headers: { authorization, 'content-type': 'application/json', connection: 'close' },
    });
    assert.equal(response.status, expectedStatus);
    assert.equal(response.headers.get(receiptHeader), signReceipt(token, authorization, expectedStatus));
    assert.deepEqual(await response.json(), { accepted: true });
  }
  assert.equal((await readStatus()).pending, 1);
  assert.ok((await stat(join(directory, 'notifications.sqlite'))).isFile());
  console.log('Gateway 安装包已通过独立启动、签名收件和 SQLite 通知去重测试');
} finally {
  gateway?.kill('SIGTERM');
  await closed;
  await rm(workspace, { recursive: true, force: true });
}
