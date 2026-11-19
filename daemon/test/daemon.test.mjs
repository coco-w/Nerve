import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { chmod, mkdtemp, rm, stat } from 'node:fs/promises';
import { request } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { setTimeout as wait } from 'node:timers/promises';
import { createAgentEvent, fromCodexHook } from '../dist/agent.js';
import { startPushGateway } from '../dist/gateway/server.js';
import { startDaemon } from '../dist/server.js';

test('Codex 原生字段映射与 Zellij 关联', () => {
  const event = fromCodexHook({
    hook_event_name: 'PermissionRequest',
    session_id: 'codex-session',
    turn_id: 'codex-turn',
    cwd: '/projects/nerve',
    tool_name: 'Bash',
    tool_input: { command: 'private command' },
  }, { ZELLIJ_SESSION_NAME: '开发', ZELLIJ_PANE_ID: '7' });

  assert.equal(event.eventType, 'agent.permission.required');
  assert.equal(event.agentSessionId, 'codex-session');
  assert.equal(event.agentTurnId, 'codex-turn');
  assert.deepEqual(event.zellij, { sessionName: '开发', paneId: 'terminal_7' });
  assert.doesNotMatch(JSON.stringify(event), /private command/);

  assert.equal(fromCodexHook({ hook_event_name: 'toString' }), undefined);
  assert.equal(createAgentEvent('omp', 'agent_end', 'omp-session', '/work', undefined, {}).zellij, undefined);
});

function http(socketPath, path, body, type = 'application/json') {
  return new Promise((resolve, reject) => {
    const req = request({
      socketPath, path, agent: false,
      method: body === undefined ? 'GET' : 'POST',
      headers: body === undefined ? {} : { 'content-type': type, 'content-length': Buffer.byteLength(body) },
      signal: AbortSignal.timeout(2500),
    }, response => {
      response.setEncoding('utf8');
      let json = '';
      response.on('data', chunk => { json += chunk; });
      response.on('error', reject);
      response.on('end', () => {
        try {
          resolve({ status: response.statusCode, body: JSON.parse(json) });
        } catch (error) {
          reject(error);
        }
      });
    });
    req.on('error', reject);
    req.end(body);
  });
}

function close(server) {
  return new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
}

test('Unix Socket 校验来源映射、并发去重及 SQLite 重启恢复', { skip: process.platform === 'win32' }, async t => {
  const home = await mkdtemp(join(tmpdir(), 'nerve-test-'));
  let daemon;
  t.after(async () => {
    if (daemon?.server.listening) await close(daemon.server);
    await rm(home, { recursive: true, force: true });
  });

  await chmod(home, 0o755);
  await assert.rejects(startDaemon(home), /私有目录/);
  await chmod(home, 0o700);

  daemon = await startDaemon(home);
  const { socketPath } = daemon;
  assert.ok((await stat(socketPath)).isSocket());
  await assert.rejects(startDaemon(home), { code: 'EADDRINUSE' });

  const health = await http(socketPath, '/v1/health');
  assert.equal(health.status, 200);
  assert.equal(health.body.schemaVersion, 1);

  const event = createAgentEvent('omp', 'session_start', 'native-session', '/nerve', undefined, {});
  const json = JSON.stringify({ ...event, messages: ['private prompt'], hostId: 'untrusted-host' });
  const responses = await Promise.all([http(socketPath, '/v1/events', json), http(socketPath, '/v1/events', json)]);
  assert.deepEqual(responses.map(result => result.status).sort(), [200, 201]);
  for (const result of responses) assert.equal(result.body.sequence, 1);

  assert.equal((await http(socketPath, '/v1/events', JSON.stringify({ ...event, cwd: '/another' }))).status, 409);
  assert.equal((await http(socketPath, '/v1/events', JSON.stringify({ ...event, eventType: 'agent.task.ended' }))).status, 422);
  assert.equal((await http(socketPath, '/v1/events', '{')).status, 400);
  assert.equal((await http(socketPath, '/v1/events', '{}', 'text/plain')).status, 415);
  assert.equal((await http(socketPath, '/v1/events', ' '.repeat(64 * 1024 + 1))).status, 413);
  assert.equal((await http(socketPath, '/v1/events?after=-1')).status, 400);

  // 遇到晚到的事件时，客户端仍可按 SQLite 序号读到新增记录。
  const older = { ...event, eventId: randomUUID(), occurredAt: event.occurredAt - 1 };
  assert.equal((await http(socketPath, '/v1/events', JSON.stringify(older))).status, 201);

  await close(daemon.server);
  daemon = await startDaemon(home);

  const page = (await http(socketPath, '/v1/events?limit=1')).body;
  assert.equal(page.nextCursor, 1);
  assert.equal(page.events[0].hostId, health.body.hostId);
  assert.equal(page.events[0].eventId, event.eventId);
  assert.doesNotMatch(JSON.stringify(page), /private prompt|untrusted-host/);
  // 通知打开时按事件 ID 定位，重启后仍返回同一条记录和主机标识。
  assert.deepEqual(await http(socketPath, '/v1/events/' + event.eventId), { status: 200, body: page.events[0] });
  assert.equal((await http(socketPath, '/v1/events/' + randomUUID())).status, 404);
  assert.equal((await http(socketPath, '/v1/events/invalid')).status, 404);
  const nextPage = (await http(socketPath, '/v1/events?after=' + page.nextCursor)).body;
  assert.deepEqual(nextPage.events.map(event => event.eventId), [older.eventId]);
  assert.equal(nextPage.nextCursor, 2);
});

async function until(check, context) {
  const deadline = performance.now() + 8_000;
  while (performance.now() < deadline) {
    if (await check()) return;
    await wait(50);
  }
  assert.fail(context);
}

function queueRows(file) {
  const db = new DatabaseSync(file, { readOnly: true, timeout: 1000 });
  try {
    return db.prepare('SELECT payload, state, last_error FROM push_queue').all();
  } finally {
    db.close();
  }
}

test('通知在 Gateway 离线时写入待投递队列，双方重启后仅投递筛选出的事件', {
  skip: process.platform === 'win32',
}, async t => {
  const root = await mkdtemp(join(tmpdir(), 'nerve-push-test-'));
  const daemonHome = join(root, 'daemon');
  const directory = join(root, 'gateway');
  const token = 'test-token-' + randomUUID();
  let daemon;
  let gateway;
  t.after(async () => {
    if (daemon?.server.listening) await close(daemon.server);
    if (gateway?.listening) await close(gateway);
    await rm(root, { recursive: true, force: true });
  });

  gateway = await startPushGateway({ directory, port: 0, token });
  const port = gateway.address().port;
  await close(gateway);
  const url = new URL('http://127.0.0.1:' + port + '/v1/notifications');

  const event = (agent, nativeEvent) => createAgentEvent(agent, nativeEvent, 'private-session-id', '/private/work',
    undefined, { ZELLIJ_SESSION_NAME: 'private-project', ZELLIJ_PANE_ID: '51' });
  // 从旧库启用推送时只入队新事件，历史 Stop 仍可正常查询。
  const previous = event('codex', 'Stop');
  daemon = await startDaemon(daemonHome);
  assert.equal((await http(daemon.socketPath, '/v1/events', JSON.stringify(previous))).status, 201);
  await close(daemon.server);

  const pushTarget = { url, token };
  daemon = await startDaemon(daemonHome, pushTarget);
  const selected = [event('codex', 'PermissionRequest'), event('codex', 'Stop'), event('omp', 'agent_end')];
  const ignored = event('omp', 'agent_start');
  for (const input of [ignored, ...selected, selected[0]]) {
    const response = await http(daemon.socketPath, '/v1/events', JSON.stringify(input));
    assert.equal(response.status, response.body.inserted ? 201 : 200);
  }
  const daemonDb = join(daemonHome, 'events.sqlite');
  await until(() => {
    const rows = queueRows(daemonDb);
    return rows.length === selected.length && rows.every(row => row.state === 'pending' && row.last_error);
  }, 'Gateway 离线时所有待投递通知应留在 SQLite');
  await close(daemon.server);

  const options = { directory, port, token };
  gateway = await startPushGateway(options);
  daemon = await startDaemon(daemonHome, pushTarget);
  const gatewayDb = join(directory, 'notifications.sqlite');
  const gatewayStatus = new URL('/v1/status', url);
  // 重启时用新连接查询，测试进程的连接池可能还保留旧服务的空闲连接。
  const headers = { authorization: 'Bearer ' + token, 'content-type': 'application/json', connection: 'close' };
  assert.equal((await fetch(gatewayStatus, { headers: { connection: 'close' }, signal: AbortSignal.timeout(2000) })).status, 401);
  const post = body => fetch(url, { method: 'POST', headers, body, signal: AbortSignal.timeout(2000) });
  assert.equal((await post('{}')).status, 422);
  assert.equal((await post(' '.repeat(4097))).status, 413);
  await until(async () => (await http(daemon.socketPath, '/v1/push/status')).body.sent === 3,
    '重启 Daemon 后应将已入库的通知送达 Gateway');
  const receipts = queueRows(gatewayDb);
  assert.equal(receipts.length, selected.length);
  assert.ok(receipts.every(row => row.state === 'pending'));
  const payloads = receipts.map(row => JSON.parse(row.payload));
  const { hostId } = (await http(daemon.socketPath, '/v1/health')).body;
  for (const { eventId, agent, eventType, occurredAt } of selected) {
    assert.deepEqual(payloads.find(payload => payload.eventId === eventId),
      { schemaVersion: 1, hostId, eventId, agent, eventType, occurredAt });
  }
  const first = payloads[0];
  assert.equal((await post(JSON.stringify({ ...first, cwd: '/untrusted' }))).status, 200);
  assert.equal((await post(JSON.stringify({ ...first, occurredAt: first.occurredAt + 1 }))).status, 409);
  assert.equal((await http(daemon.socketPath, '/v1/events')).body.events.length, 5);

  await close(gateway);
  const attempts = new Map();
  gateway = await startPushGateway({
    ...options,
    async deliver({ eventId }) {
      const attempt = (attempts.get(eventId) ?? 0) + 1;
      attempts.set(eventId, attempt);
      if (eventId === first.eventId && attempt === 1) return { state: 'retry', code: 'test_unavailable' };
      return { state: 'sent' };
    },
  });
  await until(async () => {
    const status = await fetch(gatewayStatus, { headers, signal: AbortSignal.timeout(2000) });
    return (await status.json()).sent === selected.length;
  }, 'Gateway 应恢复待投递通知，并重试暂时失败的请求');
  assert.equal(attempts.size, selected.length);
  assert.equal(attempts.get(first.eventId), 2);
  assert.ok([...attempts].every(([id, count]) => id === first.eventId || count === 1));
});
