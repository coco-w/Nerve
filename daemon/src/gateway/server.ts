import { once } from 'node:events';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { receiptHeader, secureTextEqual, signReceipt, signScheme, verifyNotification } from '../gateway-auth.js';
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
  bind?: string;
  deliver?: PushDelivery;
}

const label = '[Nerve Push Gateway]';
const bodyLimit = 4 * 1024;

export async function startPushGateway({ directory, port, token, bind = '127.0.0.1', deliver }: GatewayOptions) {
  if (!isGatewayToken(token)) throw new Error('NERVE_GATEWAY_TOKEN 应为 32–256 个字符的随机密钥');
  if (bind !== '127.0.0.1' && bind !== '0.0.0.0') {
    throw new Error('NERVE_GATEWAY_BIND 应为 127.0.0.1 或 0.0.0.0');
  }
  ensurePrivateDirectory(directory, 'NERVE_GATEWAY_HOME');
  const db = new DatabaseSync(join(directory, 'notifications.sqlite'), { timeout: 2500 });
  try {
    db.exec('PRAGMA journal_mode = WAL;');
    const queue = new PushQueue(db);
    const bearer = 'Bearer ' + token;
    const server = jsonServer(label, async (request, response) => {
      const authorization = request.headers.authorization ?? '';
      const { pathname } = new URL(request.url ?? '/', 'http://gateway.local');
      if (request.method === 'POST' && pathname === '/v1/notifications') {
        const signed = authorization.startsWith(signScheme);
        if (!signed && (bind !== '127.0.0.1' || !secureTextEqual(bearer, authorization))) {
          response.setHeader('www-authenticate', bind === '127.0.0.1' ? 'Bearer' : signScheme.trim());
          throw new RequestError(401, 'unauthorized');
        }
        const body = await readJson(request, bodyLimit, 'notification_too_large', signed ? data => {
          if (!verifyNotification(token, authorization, data)) throw new RequestError(401, 'unauthorized');
        } : undefined);
        const notification = parseNotification(body);
        if (!notification) throw new RequestError(422, 'invalid_notification');
        const result = queue.enqueue(notification);
        if (result === 'conflict') throw new RequestError(409, 'notification_id_conflict');
        // 先持久化再确认。Daemon 重发同一事件时，响应成功且不会创建第二条任务。
        const status = result === 'inserted' ? 202 : 200;
        if (signed) response.setHeader(receiptHeader, signReceipt(token, authorization, status));
        sendJson(response, status, { accepted: true });
      } else {
        // 公网实例的状态接口只供本机读取。
        if (request.socket.remoteAddress !== '127.0.0.1' || !secureTextEqual(bearer, authorization)) {
          response.setHeader('www-authenticate', 'Bearer');
          throw new RequestError(401, 'unauthorized');
        }
        if (request.method === 'GET' && pathname === '/v1/status') {
          sendJson(response, 200, { deliveryEnabled: deliver !== undefined, ...queue.status() });
        } else {
          sendJson(response, 404, { error: 'not_found' });
        }
      }
    });

    server.listen(port, bind);
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
