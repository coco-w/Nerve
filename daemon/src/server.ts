import { lstatSync, mkdirSync } from 'node:fs';
import { createServer } from 'node:http';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { join } from 'node:path';
import { parseAgentEvent } from './agent.js';
import { EventStore } from './store.js';

const bodyLimit = 64 * 1024;

function send(response: ServerResponse, status: number, body: unknown) {
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify(body));
}

class RequestError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

async function readEvent(request: IncomingMessage) {
  if (request.headers['content-type']?.split(';')[0]?.trim().toLowerCase() !== 'application/json') {
    throw new RequestError(415, 'expected_application_json');
  }
  const buffers: Buffer[] = [];
  let length = 0;
  for await (const chunk of request.iterator({ destroyOnReturn: false })) {
    length += chunk.length;
    if (length > bodyLimit) throw new RequestError(413, 'event_too_large');
    buffers.push(chunk);
  }
  let data: unknown;
  try {
    data = JSON.parse(Buffer.concat(buffers).toString('utf8'));
  } catch {
    throw new RequestError(400, 'invalid_json');
  }
  const event = parseAgentEvent(data);
  if (!event) throw new RequestError(422, 'invalid_event');
  return event;
}

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
    send(response, 200, { status: 'ok', schemaVersion: 1, hostId: store.hostId });
  } else if (request.method === 'GET' && url.pathname === '/v1/events') {
    const after = cursorParam(url.searchParams.get('after'), 0, 0, Number.MAX_SAFE_INTEGER);
    const limit = cursorParam(url.searchParams.get('limit'), 50, 1, 200);
    const events = store.after(after, limit);
    send(response, 200, { events, nextCursor: events.at(-1)?.sequence ?? after });
  } else if (request.method === 'POST' && url.pathname === '/v1/events') {
    const result = store.append(await readEvent(request));
    if (result.conflict) throw new RequestError(409, 'event_id_conflict');
    send(response, result.inserted ? 201 : 200, { sequence: result.sequence, inserted: result.inserted });
  } else {
    send(response, 404, { error: 'not_found' });
  }
}

export async function startDaemon(directory: string) {
  if (process.platform === 'win32') throw new Error('请在 WSL、Linux 或 macOS 中启动 Daemon');
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const stat = lstatSync(directory);
  // 私有 Unix Socket 以同一系统用户为信任边界，同时保护本地数据库。
  if (!stat.isDirectory() || stat.uid !== process.getuid?.() || (stat.mode & 0o077) !== 0) {
    throw new Error('NERVE_HOME 必须是当前用户拥有的私有目录（权限 0700）');
  }

  const socketPath = join(directory, 'nerve.sock');
  const store = new EventStore(join(directory, 'events.sqlite'));
  const server = createServer({ requestTimeout: 5000, headersTimeout: 3000 }, (request, response) => {
    void route(request, response, store).catch(error => {
      if (error instanceof RequestError) {
        response.setHeader('connection', 'close');
        send(response, error.status, { error: error.message });
      } else {
        console.error('[Nerve] 事件接口处理失败');
        send(response, 500, { error: 'internal_error' });
      }
    });
  });
  server.setTimeout(5000, socket => socket.destroy());
  server.once('close', () => store.close());
  try {
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject);
      server.listen(socketPath, () => {
        server.off('error', reject);
        resolve();
      });
    });
  } catch (error) {
    store.close();
    throw error;
  }
  return { server, socketPath };
}
