const { execFile } = require('node:child_process');
const dgram = require('node:dgram');
const fs = require('node:fs');
const path = require('node:path');
const { setTimeout: wait } = require('node:timers/promises');
const { promisify } = require('node:util');
const { webcrypto } = require('node:crypto');
const assert = require('node:assert/strict');

const assets = path.join(__dirname, '../../resources/rawfile/terminal/vendor');
globalThis.crypto = webcrypto;
require(path.join(assets, 'go-wasm-exec.js'));

async function bind(address, callback, port = 0) {
  const sock = dgram.createSocket('udp4');
  if (callback) sock.on('message', callback);
  await new Promise((resolve, reject) => {
    sock.once('error', reject);
    sock.bind(port, address, resolve);
  });
  return sock;
}

async function until(check, timeout = 15000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const result = await check();
    if (result) return result;
    await wait(50);
  }
  throw new Error('等待标准 mosh-server 的测试结果超时');
}

async function main() {
  // 服务器和两条模拟网络都使用环回地址，创建独立的测试 Shell。
  const startup = await promisify(execFile)(process.env.MOSH_SERVER || 'mosh-server', [
    'new', '-i', '127.0.0.1', '-p', '0', '-c', '256', '--', '/bin/sh'
  ], { timeout: 8000, env: { ...process.env, LC_ALL: 'C.UTF-8', MOSH_SERVER_NETWORK_TMOUT: '12' } });
  const [, port, key] = /^MOSH CONNECT (\d+) ([A-Za-z0-9+/]{22})\r?$/m.exec(startup.stdout);
  const go = new Go();
  const wasm = await WebAssembly.instantiate(fs.readFileSync(path.join(assets, 'nerve-mosh.wasm')), go.importObject);
  void go.run(wasm.instance);
  const engine = globalThis.nerveMoshEngine(key);
  let paint = '';
  let closed = false;
  let ended = false;
  const receive = packet => {
    const reply = engine.receive(packet);
    if (reply?.closed) closed = true;
    if (reply?.ended) ended = true;
    if (reply?.screen?.length) paint += Buffer.from(reply.screen).toString('utf8');
  };
  let socket = await bind('127.0.0.1', receive);
  const first = socket.address();
  engine.resize(80, 24);
  const tick = setInterval(() => {
    for (const packet of engine.tick() || []) {
      if (socket) socket.send(packet, Number(port), '127.0.0.1');
    }
  }, 25);
  try {
    assert.ok(engine.input(Buffer.from("count=1; printf 'NERVE_A_%s_END\\n' \"$$\"\r")));
    const [, firstPid] = await until(() => /NERVE_A_(\d+)_END/.exec(paint));
    // 有网络的空闲时间超过服务端的掉线回收阈值，终端应保持在线。
    await wait(14000);
    assert.equal(ended, false, '保活应防止服务端误把在线会话判断为掉线');
    socket.close();
    socket = null;
    assert.ok(engine.input(Buffer.from("count=$((count+1)); printf 'NERVE_B_%s_%s_END\\n' \"$$\" \"$count\"\r")));
    await wait(6000);
    socket = await bind('127.0.0.2', receive);
    engine.probe();
    const [, secondPid, count] = await until(() => /NERVE_B_(\d+)_(\d+)_END/.exec(paint));
    assert.notEqual(socket.address().address, first.address);
    assert.equal(secondPid, firstPid, '恢复后应继续使用同一个 Shell');
    assert.equal(count, '2', '重传输入应只执行一次');
    engine.shutdown();
    await until(() => closed);
    await until(async () => {
      try {
        const released = await bind('127.0.0.1', null, Number(port));
        released.close();
        return true;
      } catch (error) {
        if (error.code === 'EADDRINUSE') return false;
        throw error;
      }
    });
    console.log('通过标准 Mosh 服务端的空闲保活、断网、来源地址变化、输入去重和关闭握手测试');
  } finally {
    clearInterval(tick);
    socket?.close();
  }
}

main().catch(error => {
  console.error(error.message);
  process.exitCode = 1;
});
