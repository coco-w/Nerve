import { randomUUID } from 'node:crypto';

// 一处定义原生事件和协议类型的对应关系，适配器与 Daemon 共用。
export const codexEvents = {
  SessionStart: 'agent.session.started',
  UserPromptSubmit: 'agent.task.started',
  PermissionRequest: 'agent.permission.required',
  PreToolUse: 'agent.input.required',
  Stop: 'agent.turn.stopped',
  SessionEnd: 'agent.session.ended',
} as const;

export const ompEvents = {
  session_start: 'agent.session.started',
  agent_start: 'agent.task.started',
  agent_end: 'agent.task.ended',
  tool_execution_start: 'agent.input.required',
  tool_approval_requested: 'agent.permission.required',
  plan_review_requested: 'agent.input.required',
  session_shutdown: 'agent.session.ended',
} as const;

const eventTypes = { codex: codexEvents, omp: ompEvents };
type Agent = keyof typeof eventTypes;
type EventType = typeof codexEvents[keyof typeof codexEvents] | typeof ompEvents[keyof typeof ompEvents];

export interface ZellijLocation {
  sessionName: string;
  paneId?: string;
}

// 跨进程的 v1 事件只含定位和生命周期元数据。
export interface AgentEvent {
  schemaVersion: 1;
  eventId: string;
  agent: Agent;
  nativeEvent: string;
  eventType: EventType;
  cwd: string;
  occurredAt: number;
  agentSessionId: string;
  agentTurnId?: string;
  zellij?: ZellijLocation;
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isText(value: unknown, max: number): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= max && !value.includes('\0');
}

export const uuidPattern = /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;
const terminalPanePattern = /^terminal_\d+$/;
const sessionNamePattern = /^[^\x00-\x1f\x7f]+$/;

function getEventType(agent: Agent, nativeEvent: string): EventType | undefined {
  const mapping: Readonly<Record<string, EventType>> = eventTypes[agent];
  return Object.hasOwn(mapping, nativeEvent) ? mapping[nativeEvent] : undefined;
}

export function parseAgentEvent(input: unknown): AgentEvent | undefined {
  if (!isRecord(input)) return;

  const { schemaVersion, eventId, agent, nativeEvent, eventType, cwd, occurredAt,
    agentSessionId, agentTurnId, zellij } = input;
  if (schemaVersion !== 1 || typeof eventId !== 'string' || !uuidPattern.test(eventId)
      || (agent !== 'codex' && agent !== 'omp') || !isText(nativeEvent, 80)
      || !isText(cwd, 8192) || !isText(agentSessionId, 256)
      || typeof occurredAt !== 'number' || !Number.isSafeInteger(occurredAt) || occurredAt < 1
      || (agentTurnId !== undefined && !isText(agentTurnId, 256))) {
    return;
  }

  const expected = getEventType(agent, nativeEvent);
  if (expected === undefined || eventType !== expected) return;

  let location: ZellijLocation | undefined;
  if (zellij !== undefined) {
    if (!isRecord(zellij)) return;
    const { sessionName, paneId } = zellij;
    if (!isText(sessionName, 256) || !sessionNamePattern.test(sessionName)
        || (paneId !== undefined && (!isText(paneId, 32) || !terminalPanePattern.test(paneId)))) {
      return;
    }
    location = { sessionName, paneId };
  }

  // 只重建协议字段，原始提示词、命令和回复不会进入 SQLite。
  return { schemaVersion, eventId, agent, nativeEvent, eventType: expected, cwd, occurredAt,
    agentSessionId, agentTurnId, zellij: location };
}

function zellijFromEnv(env: NodeJS.ProcessEnv): ZellijLocation | undefined {
  // Zellij 为 Pane 进程注入会话名和数字 ID，转成 CLI 使用的 terminal_<id>。
  const sessionName = env.ZELLIJ_SESSION_NAME;
  if (!isText(sessionName, 256) || !sessionNamePattern.test(sessionName)) return;
  const rawPaneId = env.ZELLIJ_PANE_ID;
  const paneId = isText(rawPaneId, 23) && /^\d+$/.test(rawPaneId) ? 'terminal_' + rawPaneId : undefined;
  return { sessionName, paneId };
}

export function createAgentEvent(
  agent: Agent,
  nativeEvent: string,
  sessionId: unknown,
  cwd: unknown,
  turnId?: unknown,
  env = process.env,
): AgentEvent | undefined {
  return parseAgentEvent({
    schemaVersion: 1,
    eventId: randomUUID(),
    agent,
    nativeEvent,
    eventType: getEventType(agent, nativeEvent),
    cwd,
    occurredAt: Date.now(),
    agentSessionId: sessionId,
    agentTurnId: turnId,
    zellij: zellijFromEnv(env),
  });
}

export function fromCodexHook(input: unknown, env = process.env): AgentEvent | undefined {
  if (!isRecord(input) || typeof input.hook_event_name !== 'string') return;
  // 仅提问工具表示等待输入，普通工具调用不入库，也不转发问题或选项内容。
  if (input.hook_event_name === 'PreToolUse' && input.tool_name !== 'request_user_input') return;
  return createAgentEvent('codex', input.hook_event_name, input.session_id, input.cwd, input.turn_id, env);
}

// OMP 工具开始事件只筛选内置 ask；权限审批和计划选择使用各自的原生事件。
export function fromOmpEvent(input: unknown, sessionId: unknown, cwd: unknown,
  env = process.env): AgentEvent | undefined {
  if (!isRecord(input) || typeof input.type !== 'string') return;
  if (input.type === 'tool_execution_start' && input.toolName !== 'ask') return;
  return createAgentEvent('omp', input.type, sessionId, cwd, undefined, env);
}
