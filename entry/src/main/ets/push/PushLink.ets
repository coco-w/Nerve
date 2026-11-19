import { Want } from '@kit.AbilityKit';

const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;

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
