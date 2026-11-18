import { timingSafeEqual } from 'node:crypto';
import { once } from 'node:events';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { jsonServer, readJson, RequestError, sendJson } from '../http-json.js';
import { parseNotification } from '../notification.js';
import { ensurePrivateDirectory } from '../private-directory.js';
import { isGatewayToken } from '../push-client.js';
import { PushQueue, startPushWorker } from '../push-queue.js';
import type { PushDelivery } from '../push-queue.js';

interface GatewayOptions {
  directory: string;
  port: number;
  token: string;
  deliver?: PushDelivery;
}

const label = '[Nerve Push Gateway]';
const bodyLimit = 4 * 1024;

export async function startPushGateway({ directory, port, token, deliver }: GatewayOptions) {
  if (!isGatewayToken(token)) throw new Error('NERVE_GATEWAY_TOKEN 应为 32–256 个字符的随机密钥');
  ensurePrivateDirectory(directory, 'NERVE_GATEWAY_HOME');
  const db = new DatabaseSync(join(directory, 'notifications.sqlite'), { timeout: 2500 });
  try {
    db.exec('PRAGMA journal_mode = WAL;');
    const queue = new PushQueue(db);
    const authorization = Buffer.from('Bearer ' + token);
    const server = jsonServer(label, async (request, response) => {
      const received = Buffer.from(request.headers.authorization ?? '');
      if (received.length !== authorization.length || !timingSafeEqual(received, authorization)) {
        response.setHeader('www-authenticate', 'Bearer');
        throw new RequestError(401, 'unauthorized');
      }
      const { pathname } = new URL(request.url ?? '/', 'http://gateway.local');
      if (request.method === 'GET' && pathname === '/v1/status') {
        sendJson(response, 200, { deliveryEnabled: deliver !== undefined, ...queue.status() });
      } else if (request.method === 'POST' && pathname === '/v1/notifications') {
        const notification = parseNotification(await readJson(request, bodyLimit, 'notification_too_large'));
        if (!notification) throw new RequestError(422, 'invalid_notification');
        const result = queue.enqueue(notification);
        if (result === 'conflict') throw new RequestError(409, 'notification_id_conflict');
        // 先持久化再确认。Daemon 重发同一事件时，响应成功且不会创建第二条任务。
        sendJson(response, result === 'inserted' ? 202 : 200, { accepted: true });
      } else {
        sendJson(response, 404, { error: 'not_found' });
      }
    });

    // 明文 HTTP 仅监听回环地址，跨主机请求通过 HTTPS 反向代理接入。
    server.listen(port, '127.0.0.1');
    await once(server, 'listening');
    const stop = deliver && startPushWorker(queue, deliver, label);
    server.once('close', () => {
      stop?.();
      db.close();
    });
    return server;
  } catch (error) {
    db.close();
    throw error;
  }
}
