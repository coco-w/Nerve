import { createSocket } from 'node:dgram';
import type { Socket } from 'node:dgram';
import { createConnection } from 'node:net';
import { RTCPeerConnection } from 'werift';
import type { RTCDataChannel } from 'werift';
import { isRecord } from '../agent.js';
import { isSessionDescription } from './config.js';
import type { P2pHostConfig } from './config.js';

const loopback = '127.0.0.1';
const maxSshBuffer = 1024 * 1024;
const maxDatagram = 2048;
const maxPeers = 8;

// 可靠有序的通道承载 SSH 密文。反压时暂停读取本机 TCP，避免积压终端输出。
function forwardSsh(channel: RTCDataChannel, port: number) {
  const ssh = createConnection({ host: loopback, port });
  ssh.pause();
  channel.bufferedAmountLowThreshold = maxSshBuffer / 4;
  const resume = () => { if (channel.readyState === 'open') ssh.resume(); };
  channel.bufferedAmountLow.subscribe(resume);
  channel.stateChanged.subscribe(state => {
    if (state === 'open') resume();
    if (state === 'closing' || state === 'closed') ssh.destroy();
  });
  channel.onMessage.subscribe(data => {
    if (!Buffer.isBuffer(data) || ssh.writableLength + data.length > maxSshBuffer) {
      ssh.destroy();
    } else if (!ssh.destroyed) {
      ssh.write(data);
    }
  });
  ssh.on('error', () => ssh.destroy());
  ssh.once('close', () => channel.close());
  ssh.on('data', data => {
    if (channel.readyState !== 'open') return ssh.destroy();
    try {
      // 小消息避免超过鸿蒙端 SCTP 的消息上限，仍保持 TCP 字节顺序。
      for (let offset = 0; offset < data.length; offset += 16 * 1024) {
        channel.send(data.subarray(offset, offset + 16 * 1024));
      }
      if (channel.bufferedAmount >= maxSshBuffer / 2) ssh.pause();
    } catch {
      ssh.destroy();
    }
  });
  resume();
  return () => ssh.destroy();
}

function forwardTerminal(peer: RTCPeerConnection, port: number, closePeer: () => void) {
  let control: RTCDataChannel | undefined;
  let mosh: RTCDataChannel | undefined;
  let udp: Socket | undefined;
  let udpReady = false;
  let closeSsh: (() => void) | undefined;

  peer.onDataChannel.subscribe(channel => {
    if (channel.label === 'ssh' && channel.ordered && channel.maxRetransmits === null) {
      closeSsh?.();
      const close = forwardSsh(channel, port);
      closeSsh = close;
      channel.stateChanged.subscribe(state => {
        if (state === 'closed' && closeSsh === close) closeSsh = undefined;
      });
    } else if (channel.label === 'control' && channel.ordered && !control) {
      control = channel;
      channel.stateChanged.subscribe(state => { if (state === 'closed') closePeer(); });
      channel.onMessage.subscribe(data => {
        // 只准转发本机 Mosh 默认端口范围。通道内无需传送 Mosh 会话密钥。
        if (udp || typeof data !== 'string' || !/^mosh:6(?:0[0-9]{3}|1000)$/.test(data)) return;
        const socket = createSocket('udp4');
        udp = socket;
        socket.on('error', () => {
          if (udp === socket) {
            udp = undefined;
            udpReady = false;
            socket.close();
          }
        });
        socket.on('message', packet => {
          if (mosh?.readyState === 'open' && packet.length <= maxDatagram && mosh.bufferedAmount < 16 * maxDatagram) {
            mosh.send(packet);
          }
        });
        socket.connect(Number(data.slice(5)), loopback, () => { udpReady = udp === socket; });
      });
    } else if (channel.label === 'mosh' && !channel.ordered && channel.maxRetransmits === 0 && !mosh) {
      mosh = channel;
      channel.onMessage.subscribe(data => {
        // 无序通道拥塞或换网时允许丢包，由 Mosh 自身同步最新状态。
        if (udpReady && udp && Buffer.isBuffer(data) && data.length > 0 && data.length <= maxDatagram) {
          udp.send(data, () => {});
        }
      });
    } else {
      channel.close();
    }
  });
  return () => {
    closeSsh?.();
    udpReady = false;
    udp?.close();
    udp = undefined;
  };
}

export function startP2pHost(config: P2pHostConfig, hostId: string, secret: string) {
  const peers = new Map<string, () => void>();
  let signaling: WebSocket;
  let retry: NodeJS.Timeout | undefined;
  let stopped = false;

  async function acceptOffer(socket: WebSocket, id: string, sdp: string, stun: string) {
    if (peers.size >= maxPeers || peers.has(id)) {
      socket.send(JSON.stringify({ kind: 'failed', id }));
      return;
    }
    const peer = new RTCPeerConnection({ iceServers: stun ? [{ urls: stun }] : [], bundlePolicy: 'max-bundle' });
    let deadline: NodeJS.Timeout | undefined;
    const close = () => {
      if (!peers.delete(id)) return;
      clearTimeout(deadline);
      stopForwarding();
      void peer.close().catch(() => {});
    };
    const stopForwarding = forwardTerminal(peer, config.sshPort, close);
    const expire = () => {
      clearTimeout(deadline);
      deadline = setTimeout(close, 30_000).unref();
    };
    peers.set(id, close);
    expire();
    peer.connectionStateChange.subscribe(state => {
      if (state === 'connected') clearTimeout(deadline);
      // 手机换网后可能直接用新通道续接，回收失去连接的旧通道。
      if (state === 'disconnected') expire();
      if (state === 'closed' || state === 'failed') close();
    });
    try {
      await peer.setRemoteDescription({ type: 'offer', sdp });
      await peer.setLocalDescription(await peer.createAnswer());
      // 等 ICE 候选收集完成后一次发送 SDP，信令断开不影响已建立的数据通道。
      if (!peers.has(id) || socket.readyState !== WebSocket.OPEN || !peer.localDescription) {
        close();
        return;
      }
      socket.send(JSON.stringify({ kind: 'answer', id, sdp: peer.localDescription.sdp }));
    } catch {
      close();
      if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ kind: 'failed', id }));
    }
  }

  function dial() {
    const socket = new WebSocket(config.url);
    signaling = socket;
    let stun: string | undefined;
    socket.addEventListener('open', () => {
      socket.send(JSON.stringify({ kind: 'hello', role: 'daemon', hostId, secret, enrollment: config.enrollment }));
    });
    socket.addEventListener('message', event => {
      if (typeof event.data !== 'string') return;
      let message: unknown;
      try {
        message = JSON.parse(event.data);
      } catch {
        return;
      }
      if (!isRecord(message)) return;
      if (message.kind === 'ready' && typeof message.stun === 'string') stun = message.stun;
      if (message.kind === 'offer' && typeof message.id === 'string' && stun !== undefined &&
        isSessionDescription(message.sdp)) {
        void acceptOffer(socket, message.id, message.sdp, stun).catch(() => {});
      }
    });
    socket.addEventListener('close', () => {
      if (!stopped) retry = setTimeout(dial, 3_000).unref();
    });
  }

  dial();
  return () => {
    stopped = true;
    clearTimeout(retry);
    signaling.close();
    for (const close of peers.values()) close();
  };
}
