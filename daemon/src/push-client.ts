import { isRecord } from './agent.js';
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
  // 开发机可通过回环 HTTP 联调，跨主机传输使用 HTTPS。
  const localHttp = url?.protocol === 'http:' && ['127.0.0.1', '[::1]', 'localhost'].includes(url.hostname);
  if (!url || (url.protocol !== 'https:' && !localHttp)
      || url.username || url.password || url.search || url.hash || url.pathname !== '/v1/notifications') {
    throw new Error('NERVE_GATEWAY_URL 应指向 HTTPS 下的 /v1/notifications，本机回环地址可使用 HTTP');
  }
  return { url, token };
}

export function deliverToGateway({ url, token }: PushTarget): PushDelivery {
  return async (notification, signal) => {
    const response = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: 'Bearer ' + token },
      body: JSON.stringify(notification),
      redirect: 'error',
      signal,
    });
    if (response.status === 202 || response.status === 200) {
      const ack: unknown = await response.json();
      return isRecord(ack) && ack.accepted === true
        ? { state: 'sent' }
        : { state: 'retry', code: 'invalid_gateway_ack' };
    }
    await response.body?.cancel();
    const state = [400, 409, 413, 415, 422].includes(response.status) ? 'failed' : 'retry';
    return { state, code: 'gateway_http_' + response.status };
  };
}
