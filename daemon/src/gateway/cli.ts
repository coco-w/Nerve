import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { deliverToHuawei, huaweiConfigFromEnv } from './huawei.js';
import { startPushGateway } from './server.js';

async function main([command, ...args]: string[]) {
  // 源码版和独立程序共用同一入口，支持由现有服务管理器前台运行。
  if (command === '--help') {
    console.log('nerve-gateway [start] · 通过 NERVE_GATEWAY_* 和 NERVE_HUAWEI_* 配置');
    return;
  }
  if ((command !== undefined && command !== 'start') || args.length > 0) {
    throw new Error('用法为 nerve-gateway [start]');
  }
  // Gateway 有自己的监听端口和 SQLite 目录，可独立于 Daemon 部署。
  // 公网 HTTP 网关用 NERVE_GATEWAY_BIND=0.0.0.0，对通知入口强制使用签名。
  const { NERVE_GATEWAY_HOME, NERVE_GATEWAY_BIND = '127.0.0.1', NERVE_GATEWAY_PORT = '8787',
    NERVE_GATEWAY_TOKEN = '' } = process.env;
  const port = Number(NERVE_GATEWAY_PORT);
  if (!/^\d+$/.test(NERVE_GATEWAY_PORT) || !Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error('NERVE_GATEWAY_PORT 应为 1–65535 的端口号');
  }
  const directory = resolve(NERVE_GATEWAY_HOME || join(homedir(), '.nerve-gateway'));
  const huawei = huaweiConfigFromEnv(process.env);
  const server = await startPushGateway({
    directory,
    port,
    token: NERVE_GATEWAY_TOKEN,
    bind: NERVE_GATEWAY_BIND,
    deliver: huawei ? deliverToHuawei(huawei) : undefined,
  });
  const stop = () => server.close();
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
  const mode = huawei ? 'Huawei Push Kit' : '本地收件';
  console.error('[Nerve Push Gateway] 正在监听 ' + NERVE_GATEWAY_BIND + ':' + port + ' · ' + mode);
}

main(process.argv.slice(2)).catch(error => {
  console.error('[Nerve Push Gateway] ' + (error instanceof Error ? error.message : String(error)));
  process.exitCode = 1;
});
