import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { build } from 'esbuild';
import { createAgentEvent, fromCodexHook, fromOmpEvent } from '../dist/agent.js';
import { notificationFromEvent, parseNotification } from '../dist/notification.js';
import { codexHookGroups } from '../dist/setup-agents.js';
import { startDaemon } from '../dist/server.js';
import { requestJson } from '../dist/local-http.js';

test('Codex 仅将原生提问工具映射为等待回答，问题与选项不入库', () => {
  const input = { hook_event_name: 'PreToolUse', session_id: 'codex', turn_id: 'turn', cwd: '/work',
    tool_name: 'request_user_input', tool_input: { questions: [{ question: 'private-question', options: ['secret'] }] } };
  const event = fromCodexHook(input, { ZELLIJ_SESSION_NAME: 'dev', ZELLIJ_PANE_ID: '2' });
  assert.equal(event.eventType, 'agent.input.required');
  assert.equal(event.nativeEvent, 'PreToolUse');
  assert.equal(event.agentTurnId, 'turn');
  assert.deepEqual(event.zellij, { sessionName: 'dev', paneId: 'terminal_2' });
  assert.doesNotMatch(JSON.stringify(event), /private-question|secret|tool_input|questions/);
  for (const tool_name of ['Bash', 'exec_command', 'apply_patch', 'ask', undefined]) {
    assert.equal(fromCodexHook({ ...input, tool_name }), undefined);
  }
  const groups = codexHookGroups('nerve codex-hook');
  assert.equal(groups.PreToolUse[0].matcher, '^request_user_input$');
  assert.equal(groups.Stop[0].matcher, undefined);
});

test('OMP 仅筛选 ask、真实权限审批和计划选择，不转发工具参数与计划内容', () => {
  const cases = [
    [{ type: 'tool_execution_start', toolName: 'ask', args: { question: 'private-question' } }, 'agent.input.required'],
    [{ type: 'tool_approval_requested', reason: 'private-command' }, 'agent.permission.required'],
    [{ type: 'plan_review_requested', planContent: 'private-plan' }, 'agent.input.required'],
  ];
  for (const [input, expected] of cases) {
    const event = fromOmpEvent(input, 'omp', '/work', {});
    assert.equal(event.eventType, expected);
    assert.equal(event.nativeEvent, input.type);
    assert.doesNotMatch(JSON.stringify(event), /private-question|private-command|private-plan/);
  }
  for (const toolName of ['bash', 'read', 'exec', undefined]) {
    assert.equal(fromOmpEvent({ type: 'tool_execution_start', toolName }, 'omp', '/work', {}), undefined);
  }
  for (const type of ['tool_call', 'tool_result', 'tool_approval_resolved', 'plan_review_resolved', 'toString']) {
    assert.equal(fromOmpEvent({ type }, 'omp', '/work', {}), undefined);
  }
});

test('新增等待事件可由 Gateway 解析，拒绝不属于对应 Agent 的事件类型', () => {
  const hostId = '11111111-1111-4111-8111-111111111111';
  for (const [agent, nativeEvent] of [['codex', 'PreToolUse'], ['omp', 'tool_execution_start'],
    ['omp', 'tool_approval_requested'], ['omp', 'plan_review_requested']]) {
    const event = createAgentEvent(agent, nativeEvent, 'session', '/work', undefined, {});
    const notification = notificationFromEvent(hostId, event);
    assert.deepEqual(parseNotification({ ...notification, questions: ['private'] }), notification);
  }
  const end = notificationFromEvent(hostId, createAgentEvent('codex', 'Stop', 'session', '/work', undefined, {}));
  assert.equal(parseNotification({ ...end, agent: 'omp' }), undefined);
});

test('实际打包的 OMP 扩展通过 Unix Socket 上报等待事件并过滤普通工具', {
  skip: process.platform === 'win32',
}, async t => {
  const home = await mkdtemp(join(tmpdir(), 'nerve-omp-adapter-'));
  const previous = process.env.NERVE_HOME;
  process.env.NERVE_HOME = home;
  const daemon = await startDaemon(home);
  t.after(async () => {
    await new Promise(resolve => daemon.server.close(resolve));
    if (previous === undefined) delete process.env.NERVE_HOME;
    else process.env.NERVE_HOME = previous;
    await rm(home, { recursive: true, force: true });
  });
  const result = await build({ entryPoints: ['adapters/omp/extension.ts'], bundle: true,
    platform: 'node', format: 'esm', write: false });
  const { default: load } = await import('data:text/javascript;base64,' +
    Buffer.from(result.outputFiles[0].text).toString('base64'));
  const handlers = new Map();
  load({ on: (type, handler) => handlers.set(type, handler) });
  assert.equal(handlers.size, 7);
  const ctx = { cwd: '/private-workspace', sessionManager: { getSessionId: () => 'session' } };
  for (const toolName of ['read', 'bash', 'ask']) {
    await handlers.get('tool_execution_start')({ type: 'tool_execution_start', toolName,
      args: { question: 'private-question' } }, ctx);
  }
  await handlers.get('tool_approval_requested')({ type: 'tool_approval_requested', reason: 'private-command' }, ctx);
  await handlers.get('plan_review_requested')({ type: 'plan_review_requested', planContent: 'private-plan' }, ctx);
  const { events } = await requestJson('/v1/events');
  assert.deepEqual(events.map(event => event.eventType),
    ['agent.input.required', 'agent.permission.required', 'agent.input.required']);
  assert.doesNotMatch(JSON.stringify(events), /private-question|private-command|private-plan/);
});
