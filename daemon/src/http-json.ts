import { createServer } from 'node:http';
import type { IncomingMessage, ServerResponse } from 'node:http';

export class RequestError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

export function sendJson(response: ServerResponse, status: number, body: unknown) {
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify(body));
}

export async function readJson(
  request: IncomingMessage,
  limit: number,
  tooLarge: string,
  verifyBody?: (body: Buffer) => void,
): Promise<unknown> {
  if (request.headers['content-type']?.split(';')[0]?.trim().toLowerCase() !== 'application/json') {
    throw new RequestError(415, 'expected_application_json');
  }
  const buffers: Buffer[] = [];
  let length = 0;
  for await (const chunk of request.iterator({ destroyOnReturn: false })) {
    length += chunk.length;
    if (length > limit) throw new RequestError(413, tooLarge);
    buffers.push(chunk);
  }
  const body = Buffer.concat(buffers);
  verifyBody?.(body);
  try {
    return JSON.parse(body.toString('utf8'));
  } catch {
    throw new RequestError(400, 'invalid_json');
  }
}

export function jsonServer(label: string, route: (request: IncomingMessage, response: ServerResponse) => Promise<void>) {
  const server = createServer({ requestTimeout: 5000, headersTimeout: 3000 }, (request, response) => {
    void route(request, response).catch(error => {
      if (response.destroyed) return;
      // 对提前拒绝的请求关闭连接，避免余下的请求体留在复用连接上。
      response.setHeader('connection', 'close');
      if (error instanceof RequestError) {
        sendJson(response, error.status, { error: error.message });
      } else {
        console.error(label + ' 接口处理失败');
        sendJson(response, 500, { error: 'internal_error' });
      }
    });
  });
  server.setTimeout(5000, socket => socket.destroy());
  return server;
}
