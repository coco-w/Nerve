import { once } from 'node:events';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { join } from 'node:path';
import { parseAgentEvent } from './agent.js';
import { jsonServer, readJson, RequestError, sendJson } from './http-json.js';
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

async function route(request: IncomingMessage, response: ServerResponse, store: EventStore) {
  const url = new URL(request.url ?? '/', 'http://nerve.local');
  if (request.method === 'GET' && url.pathname === '/v1/health') {
    sendJson(response, 200, { status: 'ok', schemaVersion: 1, hostId: store.hostId });
  } else if (request.method === 'GET' && url.pathname === '/v1/push/status') {
    sendJson(response, 200, { enabled: store.pushEnabled, ...store.pushQueue.status() });
  } else if (request.method === 'GET' && url.pathname === '/v1/events') {
    const after = cursorParam(url.searchParams.get('after'), 0, 0, Number.MAX_SAFE_INTEGER);
    const limit = cursorParam(url.searchParams.get('limit'), 50, 1, 200);
    const events = store.after(after, limit);
    sendJson(response, 200, { events, nextCursor: events.at(-1)?.sequence ?? after });
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

export async function startDaemon(directory: string, pushTarget?: PushTarget) {
  if (process.platform === 'win32') throw new Error('请在 WSL、Linux 或 macOS 中启动 Daemon');
  ensurePrivateDirectory(directory, 'NERVE_HOME');
  const socketPath = join(directory, 'nerve.sock');
  const store = new EventStore(join(directory, 'events.sqlite'), pushTarget !== undefined);
  const server = jsonServer('[Nerve]', (request, response) => route(request, response, store));
  try {
    server.listen(socketPath);
    await once(server, 'listening');
  } catch (error) {
    store.close();
    throw error;
  }
  const stop = pushTarget && startPushWorker(store.pushQueue, deliverToGateway(pushTarget), '[Nerve]');
  server.once('close', () => {
    stop?.();
    store.close();
  });
  return { server, socketPath };
}
