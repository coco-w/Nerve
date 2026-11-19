import { randomUUID } from 'node:crypto';
import type { Server } from 'node:http';
import { WebSocket, WebSocketServer } from 'ws';
import { isRecord, uuidPattern } from '../agent.js';
import { secureTextEqual } from '../gateway-auth.js';
import { isPairingSecret, isSessionDescription, maxSignalBytes, signalingPath } from '../p2p/config.js';

export interface SignalingOptions {
  enrollment: string;
  stun: string;
  allowHttp?: boolean;
}

interface HostRegistration {
  socket: WebSocket;
  secret: string;
}

interface PendingOffer {
  app: WebSocket;
  host: WebSocket;
}

const maxSockets = 128;
const handshakeMs = 5_000;
const peerTimeoutMs = 25_000;

export function attachSignaling(server: Server, options: SignalingOptions) {
  if (!isPairingSecret(options.enrollment)) throw new Error('NERVE_P2P_ENROLL_TOKEN 应为独立的随机密钥');
  if (options.stun && (!/^stun:(?:\[[\da-fA-F:]+\]|[a-zA-Z0-9.-]+)(?::[1-9]\d{0,4})?$/.test(options.stun) ||
    !URL.canParse('http://' + options.stun.slice(5)))) {
    throw new Error('NERVE_P2P_STUN 应为 stun:主机:端口');
  }
  const signaling = new WebSocketServer({ noServer: true, maxPayload: maxSignalBytes, perMessageDeflate: false });
  const hosts = new Map<string, HostRegistration>();
  const pending = new Map<string, PendingOffer>();

  function deliver(socket: WebSocket, message: object) {
    if (socket.readyState !== WebSocket.OPEN || socket.bufferedAmount > 2 * maxSignalBytes) return false;
    socket.send(JSON.stringify(message));
    return true;
  }

  function fail(socket: WebSocket, code: string) {
    deliver(socket, { kind: 'error', code });
    socket.close(1008, code);
  }

  server.on('upgrade', (request, socket, head) => {
    // 默认只给同机 TLS 反代开放信令。内网联调可明确启用明文 WS。
    if (request.url !== signalingPath || signaling.clients.size >= maxSockets ||
      (!options.allowHttp && request.socket.remoteAddress !== '127.0.0.1')) {
      socket.destroy();
      return;
    }
    request.socket.setTimeout(0);
    signaling.handleUpgrade(request, socket, head, client => signaling.emit('connection', client));
  });

  signaling.on('connection', socket => {
    let role = '';
    let hostId = '';
    let offerId = '';
    let target: WebSocket | undefined;
    let offerTimeout: NodeJS.Timeout | undefined;
    let responding = true;
    const authTimeout = setTimeout(() => socket.terminate(), handshakeMs).unref();
    socket.on('pong', () => { responding = true; });
    const heartbeat = setInterval(() => {
      if (!responding) socket.terminate();
      else if (socket.readyState === WebSocket.OPEN) {
        responding = false;
        socket.ping();
      }
    }, 20_000).unref();
    socket.on('error', () => socket.terminate());
    socket.once('close', () => {
      clearTimeout(authTimeout);
      clearTimeout(offerTimeout);
      clearInterval(heartbeat);
      pending.delete(offerId);
      if (hosts.get(hostId)?.socket === socket) {
        hosts.delete(hostId);
        for (const [id, offer] of pending) {
          if (offer.host === socket) {
            pending.delete(id);
            fail(offer.app, 'host_offline');
          }
        }
      }
    });

    socket.on('message', (data, binary) => {
      let message: unknown;
      try {
        message = binary ? null : JSON.parse(data.toString());
      } catch {
        return fail(socket, 'invalid_message');
      }
      if (!isRecord(message)) return fail(socket, 'invalid_message');

      if (!role) {
        if (message.kind !== 'hello' || typeof message.hostId !== 'string' ||
          !uuidPattern.test(message.hostId) || !isPairingSecret(message.secret)) {
          return fail(socket, 'invalid_hello');
        }
        hostId = message.hostId;
        const current = hosts.get(hostId);
        if (message.role === 'daemon' && typeof message.enrollment === 'string' &&
          secureTextEqual(options.enrollment, message.enrollment)) {
          if (current && !secureTextEqual(current.secret, message.secret)) return fail(socket, 'pairing_denied');
          current?.socket.close(1000);
          hosts.set(hostId, { socket, secret: message.secret });
          role = 'daemon';
        } else if (message.role === 'app') {
          if (!current) return fail(socket, 'host_offline');
          if (!secureTextEqual(current.secret, message.secret)) return fail(socket, 'pairing_denied');
          target = current.socket;
          role = 'app';
        } else {
          return fail(socket, 'pairing_denied');
        }
        clearTimeout(authTimeout);
        deliver(socket, { kind: 'ready', stun: options.stun });
        return;
      }

      if (role === 'app' && message.kind === 'offer' && !offerId && isSessionDescription(message.sdp)) {
        // 一次握手使用一个标识和一个指定的 Daemon，禁止跨主机投递应答。
        if (!target || hosts.get(hostId)?.socket !== target) return fail(socket, 'host_offline');
        offerId = randomUUID();
        pending.set(offerId, { app: socket, host: target });
        offerTimeout = setTimeout(() => fail(socket, 'negotiation_timeout'), peerTimeoutMs).unref();
        if (!deliver(target, { kind: 'offer', id: offerId, sdp: message.sdp })) fail(socket, 'host_offline');
      } else if (role === 'daemon' && typeof message.id === 'string') {
        const offer = pending.get(message.id);
        if (!offer || offer.host !== socket) return;
        if (message.kind === 'answer' && isSessionDescription(message.sdp)) {
          pending.delete(message.id);
          deliver(offer.app, { kind: 'answer', sdp: message.sdp });
        } else if (message.kind === 'failed') {
          pending.delete(message.id);
          fail(offer.app, 'negotiation_failed');
        }
      } else {
        fail(socket, 'invalid_message');
      }
    });
  });

  let stopped = false;
  return () => {
    if (stopped) return;
    stopped = true;
    for (const socket of signaling.clients) socket.terminate();
    signaling.close();
  };
}
