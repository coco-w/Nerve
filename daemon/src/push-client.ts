import { isRecord } from './agent.js';
import { receiptHeader, secureTextEqual, signNotification, signReceipt } from './gateway-auth.js';
import type { PushDelivery } from './push-queue.js';

export interface PushTarget {
  url: URL;
  token: string;
}

export function isGatewayToken(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9_-]{32,256}$/.test(value);
}

export function pushTargetFromEnv(env: NodeJS.ProcessEnv): PushTarget | undefined {
  // 配置 Gateway URL 后启用通知。环境变量中只需有 Gateway 密钥，华为凭据由 Gateway 持有。
  const { NERVE_GATEWAY_URL: address, NERVE_GATEWAY_TOKEN: token } = env;
  if (!address && !token) return;
  if (!address || !isGatewayToken(token)) {
    throw new Error('请同时设置 NERVE_GATEWAY_URL 和 NERVE_GATEWAY_TOKEN');
  }
  const url = URL.parse(address);
  if (!url || (url.protocol !== 'https:' && url.protocol !== 'http:')
      || url.username || url.password || url.search || url.hash || url.pathname !== '/v1/notifications') {
    throw new Error('NERVE_GATEWAY_URL 应指向 HTTP 或 HTTPS 的 /v1/notifications');
  }
  return { url, token };
}

export function deliverToGateway({ url, token }: PushTarget, send = fetch): PushDelivery {
  // 保留本机联调和 HTTPS 入口的 Bearer 鉴权，远程 HTTP 请求使用签名。
  const signed = url.protocol === 'http:' && !['127.0.0.1', '[::1]', 'localhost'].includes(url.hostname);
  return async (notification, signal) => {
    const body = JSON.stringify(notification);
    const authorization = signed ? signNotification(token, body) : 'Bearer ' + token;
    const response = await send(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization },
      body,
      redirect: 'error',
      signal,
    });
    if (response.status === 202 || response.status === 200) {
      if (signed && !secureTextEqual(signReceipt(token, authorization, response.status),
        response.headers.get(receiptHeader) ?? '')) {
        await response.body?.cancel();
        return { state: 'retry', code: 'invalid_gateway_receipt' };
      }
      const ack: unknown = await response.json();
      return isRecord(ack) && ack.accepted === true
        ? { state: 'sent' }
        : { state: 'retry', code: 'invalid_gateway_ack' };
    }
    await response.body?.cancel();
    // HTTP 上的错误响应没有回执签名，保留队列并等待重试。
    const state = !signed && [400, 409, 413, 415, 422].includes(response.status) ? 'failed' : 'retry';
    return { state, code: 'gateway_http_' + response.status };
  };
}
