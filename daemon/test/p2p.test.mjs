import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { createSocket } from 'node:dgram';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import test from 'node:test';
import { RTCPeerConnection } from 'werift';
import { startPushGateway } from '../dist/gateway/server.js';
import { startP2pHost } from '../dist/p2p/host.js';

const loopback = '127.0.0.1';
const secret = () => randomBytes(32).toString('base64url');

async function openSignal(url, hello) {
  const socket = new WebSocket(url);
  socket.addEventListener('error', () => {});
  await once(socket, 'open', { signal: AbortSignal.timeout(4_000) });
  const incoming = once(socket, 'message', { signal: AbortSignal.timeout(4_000) });
  socket.send(JSON.stringify(hello));
  return { socket, hello: JSON.parse((await incoming)[0].data) };
}

async function waitFor(check) {
  for (let i = 0; i < 240; i++) {
    if (check()) return;
    await delay(25);
  }
  throw new Error('等待 P2P 数据通道超时');
}

async function udpEcho() {
  for (let port = 60050; port < 60100; port++) {
    const socket = createSocket('udp4');
    socket.bind(port, loopback);
    try {
      await once(socket, 'listening');
      socket.on('message', (packet, sender) => socket.send(packet, sender.port, sender.address));
      return socket;
    } catch (error) {
      socket.close();
      if (error.code !== 'EADDRINUSE') throw error;
    }
  }
  throw new Error('没有空闲的本机测试 UDP 端口');
}

test('P2P 信令校验配对并建立独立 SSH 字节流和 Mosh 数据报通道', { timeout: 30_000 }, async t => {
  const directory = await mkdtemp(join(tmpdir(), 'nerve-p2p-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const enrollment = secret();
  const hostId = randomUUID();
  const hostSecret = secret();
  const gateway = await startPushGateway({
    directory, port: 0, token: secret(), signaling: { enrollment, stun: '' },
  });
  t.after(() => {
    gateway.stopSignaling();
    gateway.close();
  });
  const url = 'ws://' + loopback + ':' + gateway.address().port + '/v1/p2p';
  const tcp = createServer(connection => connection.pipe(connection));
  tcp.listen(0, loopback);
  await once(tcp, 'listening');
  t.after(() => tcp.close());
  const udp = await udpEcho();
  t.after(() => udp.close());
  const stop = startP2pHost({ url, enrollment, sshPort: tcp.address().port }, hostId, hostSecret);
  t.after(stop);
  const hello = { kind: 'hello', role: 'app', hostId, secret: hostSecret };

  let socket;
  for (let attempt = 0; attempt < 20; attempt++) {
    const response = await openSignal(url, hello);
    if (response.hello.kind === 'ready') {
      socket = response.socket;
      break;
    }
    response.socket.close();
    assert.equal(response.hello.code, 'host_offline');
    await delay(50);
  }
  assert.ok(socket, 'Daemon 应主动注册到 Gateway');
  t.after(() => socket.close());
  const denied = await openSignal(url, { ...hello, secret: secret() });
  denied.socket.close();
  assert.deepEqual(denied.hello, { kind: 'error', code: 'pairing_denied' });

  const peer = new RTCPeerConnection({ iceServers: [] });
  t.after(() => peer.close());
  const control = peer.createDataChannel('control');
  const datagrams = peer.createDataChannel('mosh', { ordered: false, maxRetransmits: 0 });
  await peer.setLocalDescription(await peer.createOffer());
  const answerEvent = once(socket, 'message', { signal: AbortSignal.timeout(10_000) });
  socket.send(JSON.stringify({ kind: 'offer', sdp: peer.localDescription.sdp }));
  const answer = JSON.parse((await answerEvent)[0].data);
  assert.equal(answer.kind, 'answer');
  await peer.setRemoteDescription({ type: 'answer', sdp: answer.sdp });
  await waitFor(() => control.readyState === 'open' && datagrams.readyState === 'open');
  // 关闭信令连接，仍然可以收发终端数据。
  socket.close();

  const ssh = peer.createDataChannel('ssh');
  await waitFor(() => ssh.readyState === 'open');
  const sshPayload = Buffer.from('SSH-2.0-Nerve\r\n');
  let sshReply;
  ssh.onMessage.subscribe(data => { sshReply = data; });
  ssh.send(sshPayload);
  await waitFor(() => sshReply);
  assert.deepEqual(sshReply, sshPayload);
  ssh.close();

  control.send('mosh:' + udp.address().port);
  const packet = randomBytes(101);
  let reply;
  datagrams.onMessage.subscribe(data => { reply = data; });
  await waitFor(() => {
    if (!reply) datagrams.send(packet);
    return reply;
  });
  assert.deepEqual(reply, packet);
});
