import { constants, createHash, createPrivateKey, sign } from 'node:crypto';
import type { KeyObject } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { isRecord } from '../agent.js';
import type { PushDelivery } from '../push-queue.js';

interface HuaweiConfig {
  projectId: string;
  keyId: string;
  subAccount: string;
  privateKey: KeyObject;
  pushToken: string;
  category: 'WORK' | 'MARKETING';
  testMessage: boolean;
}

const jwtAudience = 'https://oauth-login.cloud.huawei.com/oauth2/v3/token';
const jwtLifetime = 3600;

export function huaweiConfigFromEnv(env: NodeJS.ProcessEnv): HuaweiConfig | undefined {
  // 服务账号 JSON 与设备 Push Token 只在 Gateway 进程中读取。
  const { NERVE_HUAWEI_SERVICE_ACCOUNT_FILE: file, NERVE_HUAWEI_PUSH_TOKEN: pushToken,
    NERVE_HUAWEI_CATEGORY: category = 'WORK', NERVE_HUAWEI_TEST_MESSAGE: testMessage = '0' } = env;
  if (!file && !pushToken) return;
  if (!file || !pushToken?.trim()) {
    throw new Error('请同时设置 NERVE_HUAWEI_SERVICE_ACCOUNT_FILE 和 NERVE_HUAWEI_PUSH_TOKEN');
  }
  if (category !== 'WORK' && category !== 'MARKETING') {
    throw new Error('NERVE_HUAWEI_CATEGORY 应为 WORK 或 MARKETING');
  }
  if (testMessage !== '0' && testMessage !== '1') {
    throw new Error('NERVE_HUAWEI_TEST_MESSAGE 应为 0 或 1');
  }
  let account: unknown;
  try {
    account = JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    throw new Error('无法读取华为服务账号 JSON');
  }
  if (!isRecord(account) || typeof account.project_id !== 'string' || !/^[\w-]+$/.test(account.project_id)
      || typeof account.key_id !== 'string' || !account.key_id || typeof account.sub_account !== 'string'
      || !account.sub_account || typeof account.private_key !== 'string') {
    throw new Error('华为服务账号 JSON 缺少有效的 project_id、key_id、sub_account 或 private_key');
  }
  let privateKey: KeyObject;
  try {
    privateKey = createPrivateKey(account.private_key);
  } catch {
    throw new Error('无法读取华为服务账号的 PEM 私钥');
  }
  if (privateKey.asymmetricKeyType !== 'rsa' || (privateKey.asymmetricKeyDetails?.modulusLength ?? 0) < 2048) {
    throw new Error('华为服务账号需要至少 2048 位的 RSA 私钥');
  }
  return { projectId: account.project_id, keyId: account.key_id, subAccount: account.sub_account,
    privateKey, pushToken: pushToken.trim(), category, testMessage: testMessage === '1' };
}

function encode(value: unknown) {
  return Buffer.from(JSON.stringify(value)).toString('base64url');
}

export function deliverToHuawei(config: HuaweiConfig, send: typeof fetch = fetch): PushDelivery {
  const url = 'https://push-api.cloud.huawei.com/v3/' + config.projectId + '/messages:send';
  const header = encode({ kid: config.keyId, typ: 'JWT', alg: 'PS256' });
  let cachedJwt = '';
  let expires = 0;

  function authorization() {
    const now = Math.floor(Date.now() / 1000);
    if (!cachedJwt || now >= expires - 60 || now < expires - jwtLifetime) {
      // JWT 直接用于 Push Kit V3。PS256 使用 SHA-256 和 32 字节的 PSS 盐。
      expires = now + jwtLifetime;
      const content = header + '.' + encode({ aud: jwtAudience, iss: config.subAccount, iat: now, exp: expires });
      const signature = sign('sha256', Buffer.from(content), {
        key: config.privateKey,
        padding: constants.RSA_PKCS1_PSS_PADDING,
        saltLength: constants.RSA_PSS_SALTLEN_DIGEST,
      });
      cachedJwt = content + '.' + signature.toString('base64url');
    }
    return 'Bearer ' + cachedJwt;
  }

  return async (notification, signal) => {
    const { eventId, hostId, agent, eventType } = notification;
    const agentName = agent === 'codex' ? 'Codex' : 'OMP';
    // 同一主机事件的各次投递都使用相同的应用消息标识。
    const appMessageId = createHash('sha256').update(hostId + ':' + eventId).digest('base64url');
    const response = await send(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: authorization(), 'push-type': '0' },
      redirect: 'error',
      signal,
      body: JSON.stringify({
        payload: {
          notification: {
            category: config.category,
            title: 'Nerve · ' + agentName,
            body: eventType === 'agent.permission.required' ? '请求权限，等待你的处理。' : '本轮运行已结束。',
            appMessageId,
            clickAction: { actionType: 0, data: { hostId, eventId } },
          },
        },
        pushOptions: { testMessage: config.testMessage },
        target: { token: [config.pushToken] },
      }),
    });

    const body: unknown = await response.json().catch(() => undefined);
    const code = isRecord(body) && typeof body.code === 'string' && /^\d{8}$/.test(body.code)
      ? body.code
      : undefined;
    if (response.ok && code === '80000000') return { state: 'sent' };
    if (code === '80200005') cachedJwt = '';
    const retryable = code === '80200005' || code === '81000001' || response.status === 408
      || response.status === 429 || response.status >= 500 || (response.ok && !code);
    // Push Kit 的 msg 可能含设备 Token，日志只保留业务码或 HTTP 状态。
    return { state: retryable ? 'retry' : 'failed', code: code ? 'huawei_' + code : 'huawei_http_' + response.status };
  };
}
