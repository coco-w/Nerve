import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { chmod, mkdtemp, rm, stat } from 'node:fs/promises';
import { request } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createAgentEvent, fromCodexHook } from '../dist/agent.js';
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
  const nextPage = (await http(socketPath, '/v1/events?after=' + page.nextCursor)).body;
  assert.deepEqual(nextPage.events.map(event => event.eventId), [older.eventId]);
  assert.equal(nextPage.nextCursor, 2);
});
