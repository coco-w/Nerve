export const signalingPath = '/v1/p2p';
export const maxSignalBytes = 64 * 1024;

export function isPairingSecret(secret: unknown): secret is string {
  return typeof secret === 'string' && /^[A-Za-z0-9_-]{43,128}$/.test(secret);
}

export function isSessionDescription(sdp: unknown): sdp is string {
  return typeof sdp === 'string' && sdp.length <= 48 * 1024 && sdp.startsWith('v=0');
}

export interface P2pHostConfig {
  url: string;
  enrollment: string;
  sshPort: number;
}

export function p2pHostFromEnv(env: NodeJS.ProcessEnv): P2pHostConfig | undefined {
  // 仅配置通知的开发机仍走原有链路。终端注册使用独立凭据。
  const { NERVE_P2P_URL: address, NERVE_P2P_ENROLL_TOKEN: enrollment, NERVE_P2P_SSH_PORT = '22' } = env;
  if (!address && !enrollment) return undefined;
  const url = address && URL.parse(address);
  if (!url || !['ws:', 'wss:'].includes(url.protocol) || url.pathname !== signalingPath ||
    url.username || url.password || url.search || url.hash) {
    throw new Error('NERVE_P2P_URL 应指向 ws 或 wss 的 ' + signalingPath);
  }
  if (!isPairingSecret(enrollment)) throw new Error('NERVE_P2P_ENROLL_TOKEN 应为独立的随机密钥');
  const sshPort = Number(NERVE_P2P_SSH_PORT);
  if (!/^\d{1,5}$/.test(NERVE_P2P_SSH_PORT) || sshPort < 1 || sshPort > 65535) {
    throw new Error('NERVE_P2P_SSH_PORT 应为 1–65535 的本机 SSH 端口');
  }
  return { url: url.href, enrollment, sshPort };
}
