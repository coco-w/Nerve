import assert from 'node:assert/strict';
import { constants, generateKeyPairSync, randomUUID, verify } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';
import { createAgentEvent } from '../dist/agent.js';
import { receiptHeader, signNotification, signReceipt } from '../dist/gateway-auth.js';
import { deliverToHuawei, huaweiConfigFromEnv } from '../dist/gateway/huawei.js';
import { startPushGateway } from '../dist/gateway/server.js';
import { notificationFromEvent } from '../dist/notification.js';
import { deliverToGateway, pushTargetFromEnv } from '../dist/push-client.js';
import { PushQueue } from '../dist/push-queue.js';
import { EventStore } from '../dist/store.js';

test('Gateway 通知地址支持远程 HTTP、HTTPS 与本机联调', () => {
  assert.equal(pushTargetFromEnv({}), undefined);
  const env = { NERVE_GATEWAY_TOKEN: 'test-token-' + randomUUID() };
  assert.throws(() => pushTargetFromEnv(env), /同时设置/);
  for (const url of ['http://gateway.example/v1/notifications', 'https://gateway.example/v1/notifications',
    'http://127.0.0.1:8787/v1/notifications']) {
    assert.equal(pushTargetFromEnv({ ...env, NERVE_GATEWAY_URL: url }).url.href, url);
  }
  assert.throws(() => pushTargetFromEnv({ ...env, NERVE_GATEWAY_URL: 'ftp://gateway.example/v1/notifications' }),
    /HTTP 或 HTTPS/);
});

test('公网 HTTP 通知验证签名、有效期和入库回执，重发仍然去重', async t => {
  const root = await mkdtemp(join(tmpdir(), 'nerve-signed-http-'));
  const token = 'test-token-' + randomUUID();
  const gateway = await startPushGateway({ directory: root, bind: '0.0.0.0', port: 0, token });
  t.after(async () => {
    await new Promise(resolve => gateway.close(resolve));
    await rm(root, { recursive: true, force: true });
  });
  const local = new URL('http://127.0.0.1:' + gateway.address().port + '/v1/notifications');
  const target = { url: new URL('http://gateway.example/v1/notifications'), token };
  const event = createAgentEvent('codex', 'Stop', 'test-session', '/tmp', undefined, {});
  const notification = notificationFromEvent(randomUUID(), event);
  const body = JSON.stringify(notification);
  const signal = AbortSignal.timeout(5000);
  const post = (authorization, payload = body) => fetch(local, {
    method: 'POST', headers: { 'content-type': 'application/json', authorization }, body: payload, signal,
  });
  const current = signNotification(token, body);
  for (const request of [post('Bearer ' + token), post(signNotification(token, body, Date.now() - 360_000)),
    post(current, body + ' ')]) {
    const response = await request;
    assert.equal(response.status, 401);
    await response.body.cancel();
  }

  let accepted = 0;
  const deliver = deliverToGateway(target, async (_url, request) => {
    const authorization = request.headers.authorization;
    assert.match(authorization, /^Nerve-HMAC [0-9]+\.[A-Za-z0-9_-]{43}$/);
    assert.ok(!authorization.includes(token));
    const response = await fetch(local, request);
    assert.equal(response.status, accepted++ === 0 ? 202 : 200);
    assert.equal(response.headers.get(receiptHeader), signReceipt(token, authorization, response.status));
    return response;
  });
  assert.deepEqual(await deliver(notification, signal), { state: 'sent' });
  assert.deepEqual(await deliver(notification, signal), { state: 'sent' });
  const status = await fetch(new URL('/v1/status', local), {
    headers: { authorization: 'Bearer ' + token }, signal,
  });
  assert.equal((await status.json()).pending, 1);

  const forged = deliverToGateway(target, async () => Response.json({ accepted: true }, { status: 202 }));
  assert.deepEqual(await forged(notification, signal), { state: 'retry', code: 'invalid_gateway_receipt' });
  const forgedRejection = deliverToGateway(target, async () => new Response(null, { status: 422 }));
  assert.deepEqual(await forgedRejection(notification, signal), { state: 'retry', code: 'gateway_http_422' });
});

test('事件和待发送记录在同一 SQLite 事务中回滚', async t => {
  const root = await mkdtemp(join(tmpdir(), 'nerve-push-atomic-'));
  const file = join(root, 'events.sqlite');
  const store = new EventStore(file, true);
  const db = new DatabaseSync(file);
  t.after(async () => {
    db.close();
    store.close();
    await rm(root, { recursive: true, force: true });
  });
  const input = createAgentEvent('codex', 'Stop', 'session', '/workspace', undefined, {});
  db.exec(`CREATE TRIGGER reject_push BEFORE INSERT ON push_queue BEGIN
    SELECT RAISE(ABORT, 'fixture enqueue failure');
  END;`);
  assert.throws(() => store.append(input), /fixture enqueue failure/);
  assert.deepEqual(store.after(0, 10), []);
  assert.equal(store.pushQueue.status().pending, 0);
  db.exec('DROP TRIGGER reject_push');
  assert.equal(store.append(input).inserted, true);
  assert.equal(store.pushQueue.status().pending, 1);
});

test('同一通知的租约阻止并发认领，租约失效后可恢复且旧结果不能覆盖', async t => {
  const root = await mkdtemp(join(tmpdir(), 'nerve-push-lease-'));
  const file = join(root, 'notifications.sqlite');
  const db = new DatabaseSync(file);
  const otherDb = new DatabaseSync(file);
  t.after(async () => {
    otherDb.close();
    db.close();
    await rm(root, { recursive: true, force: true });
  });
  const queue = new PushQueue(db);
  const other = new PushQueue(otherDb);
  const time = Date.now();
  const event = createAgentEvent('omp', 'agent_end', 'session', '/workspace', undefined, {});
  const notification = notificationFromEvent(randomUUID(), event);
  assert.equal(queue.enqueue(notification, time), 'inserted');
  const original = queue.claim(time);
  assert.deepEqual(original.notification, notification);
  assert.equal(other.claim(time), undefined);
  const recovered = other.claim(time + 60_000);
  assert.deepEqual(recovered.notification, original.notification);
  assert.equal(recovered.attempt, original.attempt + 1);
  queue.finish(original, { state: 'failed', code: 'late_response' }, time + 60_000);
  assert.deepEqual(queue.status(), { pending: 1, sent: 0, failed: 0 });
  other.finish(recovered, { state: 'sent' }, time + 60_001);
  assert.equal(queue.enqueue(notification, time + 60_002), 'duplicate');
  assert.deepEqual(queue.status(), { pending: 0, sent: 1, failed: 0 });
});

test('Huawei V3 请求使用可验签的 PS256、稳定消息标识和官方响应码', async t => {
  const root = await mkdtemp(join(tmpdir(), 'nerve-huawei-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const file = join(root, 'service-account.json');
  await writeFile(file, JSON.stringify({
    project_id: 'test-project',
    key_id: 'test-key',
    sub_account: 'test-account',
    private_key: privateKey.export({ type: 'pkcs8', format: 'pem' }),
  }), { mode: 0o600 });
  const config = huaweiConfigFromEnv({
    NERVE_HUAWEI_SERVICE_ACCOUNT_FILE: file,
    NERVE_HUAWEI_PUSH_TOKEN: 'device-token-fixture',
    NERVE_HUAWEI_TEST_MESSAGE: '1',
  });
  const requests = [];
  const replies = [[503, '81000001'], [401, '80200005'], [200, '80000000'], [400, '80300007']];
  const deliver = deliverToHuawei(config, async (url, request) => {
    requests.push({ url, ...request, body: JSON.parse(request.body) });
    const [status, code] = replies.shift();
    return Response.json({ code, msg: 'device-token-fixture' }, { status });
  });
  const event = createAgentEvent('codex', 'PermissionRequest', 'private', '/private/work', undefined, {});
  const notification = notificationFromEvent(randomUUID(), event);
  const signal = new AbortController().signal;
  assert.deepEqual(await deliver(notification, signal), { state: 'retry', code: 'huawei_81000001' });
  assert.deepEqual(await deliver(notification, signal), { state: 'retry', code: 'huawei_80200005' });
  assert.deepEqual(await deliver(notification, signal), { state: 'sent' });
  assert.deepEqual(await deliver(notification, signal), { state: 'failed', code: 'huawei_80300007' });

  const [first, second, refreshed] = requests;
  assert.equal(first.url, 'https://push-api.cloud.huawei.com/v3/test-project/messages:send');
  assert.equal(first.method, 'POST');
  assert.equal(first.headers['push-type'], '0');
  assert.equal(first.redirect, 'error');
  assert.equal(first.headers.authorization, second.headers.authorization);
  assert.notEqual(first.headers.authorization, refreshed.headers.authorization);
  const [header, claims, signature] = refreshed.headers.authorization.slice(7).split('.');
  const decode = part => JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
  assert.deepEqual(decode(header), { kid: 'test-key', typ: 'JWT', alg: 'PS256' });
  const fields = decode(claims);
  assert.equal(fields.iss, 'test-account');
  assert.equal(fields.aud, 'https://oauth-login.cloud.huawei.com/oauth2/v3/token');
  assert.equal(fields.exp - fields.iat, 3600);
  assert.equal(verify('sha256', Buffer.from(header + '.' + claims), {
    key: publicKey,
    padding: constants.RSA_PKCS1_PSS_PADDING,
    saltLength: 32,
  }, Buffer.from(signature, 'base64url')), true);

  const alert = first.body.payload.notification;
  assert.equal(alert.category, 'WORK');
  assert.match(alert.appMessageId, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(alert.appMessageId, refreshed.body.payload.notification.appMessageId);
  assert.deepEqual(alert.clickAction, {
    actionType: 0, data: { hostId: notification.hostId, eventId: notification.eventId },
  });
  assert.deepEqual(first.body.target.token, ['device-token-fixture']);
  assert.equal(first.body.pushOptions.testMessage, true);
  assert.doesNotMatch(JSON.stringify(first.body), /private|service-account/);
});
