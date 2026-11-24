import { codexEvents, isRecord, ompEvents, uuidPattern } from './agent.js';
import type { AgentEvent } from './agent.js';

type NotificationEventType = typeof codexEvents.PermissionRequest | typeof codexEvents.Stop
  | typeof codexEvents.PreToolUse | typeof ompEvents.agent_end;

// 这是出主机的通知协议。工作路径、Agent 对话和 Zellij 会话名留在本机。
export interface PushNotification {
  schemaVersion: 1;
  hostId: string;
  eventId: string;
  agent: AgentEvent['agent'];
  eventType: NotificationEventType;
  occurredAt: number;
}

function isNotifiable(agent: unknown, type: unknown): type is NotificationEventType {
  return (agent === 'codex' && (type === codexEvents.PermissionRequest || type === codexEvents.Stop
    || type === codexEvents.PreToolUse))
    || (agent === 'omp' && (type === ompEvents.agent_end || type === ompEvents.tool_approval_requested
      || type === ompEvents.tool_execution_start));
}

export function notificationFromEvent(hostId: string, event: AgentEvent): PushNotification | undefined {
  const { eventId, agent, eventType, occurredAt } = event;
  if (!isNotifiable(agent, eventType)) return;
  return { schemaVersion: 1, hostId, eventId, agent, eventType, occurredAt };
}

export function parseNotification(input: unknown): PushNotification | undefined {
  if (!isRecord(input)) return;
  const { schemaVersion, hostId, eventId, agent, eventType, occurredAt } = input;
  if (schemaVersion !== 1 || typeof hostId !== 'string' || !uuidPattern.test(hostId)
      || typeof eventId !== 'string' || !uuidPattern.test(eventId)
      || (agent !== 'codex' && agent !== 'omp') || !isNotifiable(agent, eventType)
      || typeof occurredAt !== 'number' || !Number.isSafeInteger(occurredAt) || occurredAt < 1) {
    return;
  }
  // 重建白名单字段，保证重试时可按规范化后的内容判重。
  return { schemaVersion, hostId, eventId, agent, eventType, occurredAt };
}
