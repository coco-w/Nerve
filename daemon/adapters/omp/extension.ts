import type { ExtensionAPI, ExtensionContext } from '@oh-my-pi/pi-coding-agent';
import { createAgentEvent, ompEvents } from '../../dist/agent.js';
import { requestJson } from '../../dist/local-http.js';

export default function nerveExtension(omp: ExtensionAPI) {
  async function forward(name: keyof typeof ompEvents, ctx: ExtensionContext) {
    try {
      // 通过 OMP 的扩展上下文获取当前会话，保留 Agent 与 Zellij 的独立标识。
      const event = createAgentEvent('omp', name, ctx.sessionManager.getSessionId(), ctx.cwd);
      if (event) await requestJson('/v1/events', event, 750);
    } catch {
      // 即使 Daemon 暂未启动，OMP 仍保持原有的执行流程。
      process.stderr.write('[Nerve] OMP 事件未送达本地 Daemon\n');
    }
  }

  omp.on('session_start', (_event, ctx) => forward('session_start', ctx));
  omp.on('agent_start', (_event, ctx) => forward('agent_start', ctx));
  omp.on('agent_end', (_event, ctx) => forward('agent_end', ctx));
  omp.on('session_shutdown', (_event, ctx) => forward('session_shutdown', ctx));
}
