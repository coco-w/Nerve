import { createHmac, timingSafeEqual } from 'node:crypto';

export const signScheme = 'Nerve-HMAC ';
export const receiptHeader = 'x-nerve-receipt';
const signatureWindowMs = 5 * 60 * 1000;

export function secureTextEqual(expected: string, received: string): boolean {
  const left = Buffer.from(expected);
  const right = Buffer.from(received);
  return left.length === right.length && timingSafeEqual(left, right);
}

// HTTP 上只发送签名，网关密钥不随请求传输。签名覆盖时间和原始消息体。
export function signNotification(token: string, body: string | Buffer, timestamp = Date.now()): string {
  const signature = createHmac('sha256', token)
    .update('nerve-push-v1\nPOST\n/v1/notifications\n' + timestamp + '\n')
    .update(body)
    .digest('base64url');
  return signScheme + timestamp + '.' + signature;
}

export function verifyNotification(token: string, authorization: string, body: Buffer): boolean {
  const match = /^Nerve-HMAC ([0-9]{1,16})\.[A-Za-z0-9_-]{43}$/.exec(authorization);
  if (!match) return false;
  const timestamp = Number(match[1]);
  return Number.isSafeInteger(timestamp) && Math.abs(Date.now() - timestamp) <= signatureWindowMs
    && secureTextEqual(signNotification(token, body, timestamp), authorization);
}

// 把入库回执绑定到本次签名请求，防止 HTTP 链路上的伪造响应清空待发队列。
export function signReceipt(token: string, authorization: string, status: number): string {
  return createHmac('sha256', token)
    .update('nerve-push-receipt-v1\n' + authorization + '\n' + status)
    .digest('base64url');
}
