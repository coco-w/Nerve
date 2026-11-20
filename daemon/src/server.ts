import { once } from 'node:events';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { join } from 'node:path';
import { parseAgentEvent, uuidPattern } from './agent.js';
import { jsonServer, readJson, RequestError, sendJson } from './http-json.js';
import type { P2pHostConfig } from './p2p/config.js';
import { ensurePrivateDirectory } from './private-directory.js';
import { deliverToGateway } from './push-client.js';
import type { PushTarget } from './push-client.js';
import { startPushWorker } from './push-queue.js';
import { EventStore } from './store.js';

const bodyLimit = 64 * 1024;

function cursorParam(value: string | null, fallback: number, min: number, max: number) {
  if (value === null) return fallback;
  const number = Number(value);
  if (!/^\d+$/.test(value) || !Number.isSafeInteger(number) || number < min || number > max) {
    throw new RequestError(400, 'invalid_pagination');
  }
  return number;
}

async function route(request: IncomingMessage, response: ServerResponse, store: EventStore, stop: () => void,
  pairing: string) {
  const url = new URL(request.url ?? '/', 'http://nerve.local');
  if (request.method === 'GET' && url.pathname === '/v1/health') {
    sendJson(response, 200, { status: 'ok', schemaVersion: 1, hostId: store.hostId });
  } else if (request.method === 'GET' && url.pathname === '/v1/push/status') {
    sendJson(response, 200, { enabled: store.pushEnabled, ...store.pushQueue.status() });
  } else if (request.method === 'GET' && url.pathname === '/v1/p2p/pairing') {
    if (!pairing) throw new RequestError(404, 'p2p_disabled');
    sendJson(response, 200, { pairing });
  } else if (request.method === 'POST' && url.pathname === '/v1/shutdown') {
    await readJson(request, 64, 'shutdown_request_too_large');
    // 先停监听，再回复停止指令，便于客户端随后重新启动。
    stop();
    response.setHeader('connection', 'close');
    sendJson(response, 200, { status: 'stopping' });
  } else if (request.method === 'GET' && url.pathname === '/v1/events') {
    const after = cursorParam(url.searchParams.get('after'), 0, 0, Number.MAX_SAFE_INTEGER);
    const limit = cursorParam(url.searchParams.get('limit'), 50, 1, 200);
    const events = store.after(after, limit);
    sendJson(response, 200, { events, nextCursor: events.at(-1)?.sequence ?? after });
  } else if (request.method === 'GET' && url.pathname.startsWith('/v1/events/')) {
    // 此查询仍经私有 Unix Socket，通知通过 SSH 在对应开发机上解析。
    const eventId = url.pathname.slice('/v1/events/'.length);
    const event = uuidPattern.test(eventId) ? store.find(eventId) : undefined;
    if (!event) throw new RequestError(404, 'event_not_found');
    sendJson(response, 200, event);
  } else if (request.method === 'POST' && url.pathname === '/v1/events') {
    const event = parseAgentEvent(await readJson(request, bodyLimit, 'event_too_large'));
    if (!event) throw new RequestError(422, 'invalid_event');
    const result = store.append(event);
    if (result.conflict) throw new RequestError(409, 'event_id_conflict');
    sendJson(response, result.inserted ? 201 : 200, { sequence: result.sequence, inserted: result.inserted });
  } else {
    sendJson(response, 404, { error: 'not_found' });
  }
}

export async function startDaemon(directory: string, pushTarget?: PushTarget, p2p?: P2pHostConfig) {
  if (process.platform === 'win32') throw new Error('请在 WSL、Linux 或 macOS 中启动 Daemon');
  const p2pModule = p2p && await import('./p2p/host.js');
  ensurePrivateDirectory(directory, 'NERVE_HOME');
  const socketPath = join(directory, 'nerve.sock');
  let store: EventStore | undefined;
  let pairing = '';
  // 停止命令走同一个用户私有 Socket，无需根据 PID 猜测要停止的进程。
  const server = jsonServer('[Nerve]', async (request, response) => {
    if (!store) throw new RequestError(503, 'daemon_starting');
    return route(request, response, store, stopListening, pairing);
  });
  function stopListening() {
    server.close();
  }
  // 先占用 Socket，再初始化 SQLite，避免并发启动时两个进程同时创建数据库。
  server.listen(socketPath);
  await once(server, 'listening');

  let stopPush: (() => void) | undefined;
  let stopP2p: (() => void) | undefined;
  server.once('close', () => {
    stopP2p?.();
    stopPush?.();
    store?.close();
  });
  try {
    store = new EventStore(join(directory, 'events.sqlite'), pushTarget !== undefined);
    const p2pSecret = p2p ? store.p2pSecret() : '';
    // URL 片段用于给 App 配对，连接信令服务时只用前面的 WebSocket 地址。
    pairing = p2p ? p2p.url + '#' + store.hostId + '.' + p2pSecret : '';
    stopPush = pushTarget && startPushWorker(store.pushQueue, deliverToGateway(pushTarget), '[Nerve]');
    stopP2p = p2p && p2pModule?.startP2pHost(p2p, store.hostId, p2pSecret);
  } catch (error) {
    stopListening();
    throw error;
  }
  return { server, socketPath };
}
