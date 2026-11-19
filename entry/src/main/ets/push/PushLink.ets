import { Want } from '@kit.AbilityKit';

const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;

interface NerveDaemonHealth {
  status: string;
  schemaVersion: number;
  hostId: string;
}

// 仅信任已校验 SSH 连接上的 nerve health 响应，不用通知里的 ID 建立绑定。
export function hostIdFromDaemonHealth(output: string): string {
  try {
    const health = JSON.parse(output) as NerveDaemonHealth | null;
    if (health && health.status === 'ok' && health.schemaVersion === 1 &&
      typeof health.hostId === 'string' && UUID.test(health.hostId)) {
      return health.hostId;
    }
  } catch (_) {
    // 独立 SSH 主机可能没有运行 Nerve，健康检查不影响终端连接。
  }
  return '';
}

export function readPushLink(want: Want): string {
  const hostId = want.parameters?.['hostId'];
  const eventId = want.parameters?.['eventId'];
  // Ability 可被外部启动，只接受 Gateway 协议使用的两个 UUID。
  if (typeof hostId !== 'string' || typeof eventId !== 'string' ||
    hostId.length !== 36 || eventId.length !== 36 || !UUID.test(hostId) || !UUID.test(eventId)) {
    return '';
  }
  return hostId + ':' + eventId;
}
