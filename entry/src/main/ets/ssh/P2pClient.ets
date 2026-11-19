import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { applyPeerAnswer, createPeer, peerOffer, PeerHandle, peerState, releasePeer } from 'libnerve_ssh.so';

export interface P2pPairing {
  url: string;
  hostId: string;
  secret: string;
}

interface P2pSignal {
  kind: string;
  stun?: string;
  sdp?: string;
  code?: string;
}

interface P2pHello {
  kind: string;
  role: string;
  hostId: string;
  secret: string;
}

interface P2pOffer {
  kind: string;
  sdp: string;
}

export function parseP2pPairing(input: string): P2pPairing | undefined {
  // 已保存主机的非秘密部分只有地址和主机 ID，凭据从加密库单独读取。
  const match = /^(wss?:\/\/(?:\[[\dA-Fa-f:]+\]|[a-zA-Z0-9.-]+)(?::\d{1,5})?\/v1\/p2p)#([\da-f]{8}-[\da-f]{4}-4[\da-f]{3}-[89ab][\da-f]{3}-[\da-f]{12})(?:\.([a-zA-Z0-9_-]{43,128}))?$/
    .exec(input.trim());
  return match ? { url: match[1], hostId: match[2], secret: match[3] ?? '' } : undefined;
}

function signalingError(code?: string): Error {
  if (code === 'host_offline') return new Error('开发机未连接 P2P Gateway。');
  if (code === 'pairing_denied') return new Error('P2P 配对凭据失效，请重新获取配对地址。');
  return new Error('P2P 协商失败，请检查两端的 UDP 网络。');
}

export async function dialP2p(pairing: P2pPairing, current: () => boolean): Promise<PeerHandle> {
  const socket = webSocket.createWebSocket();
  let handle: PeerHandle | undefined;
  let accepted = false;
  let timer = -1;
  try {
    const peer = await new Promise<PeerHandle>((resolve, reject) => {
      let offered = false;
      let answered = false;
      const deadline = Date.now() + 32_000;
      const unavailable = (): void => reject(new Error('无法连接 P2P Gateway，请检查信令地址和网络。'));
      socket.on('open', (error: BusinessError): void => {
        if (error) {
          unavailable();
          return;
        }
        const hello: P2pHello = { kind: 'hello', role: 'app', hostId: pairing.hostId, secret: pairing.secret };
        socket.send(JSON.stringify(hello)).catch(unavailable);
      });
      socket.on('message', (error: BusinessError, data: string | ArrayBuffer): void => {
        if (error || typeof data !== 'string' || data.length > 65536 || !current()) return;
        try {
          const signal = JSON.parse(data) as P2pSignal;
          if (signal.kind === 'ready' && !handle) {
            handle = createPeer(signal.stun ?? '');
          } else if (signal.kind === 'answer' && offered && !answered && handle && signal.sdp) {
            applyPeerAnswer(handle, signal.sdp);
            answered = true;
          } else if (signal.kind === 'error') {
            reject(signalingError(signal.code));
          }
        } catch (_) {
          reject(signalingError());
        }
      });
      socket.on('error', unavailable);
      socket.on('close', unavailable);
      timer = setInterval((): void => {
        if (!current() || Date.now() >= deadline) {
          reject(new Error('P2P 打洞未建立，请检查 STUN 和两端的 UDP 网络。'));
          return;
        }
        if (!handle) return;
        try {
          const state = peerState(handle);
          if (state < 0) reject(signalingError());
          if (!offered) {
            const sdp = peerOffer(handle);
            if (sdp) {
              const offer: P2pOffer = { kind: 'offer', sdp };
              offered = true;
              socket.send(JSON.stringify(offer)).catch(unavailable);
            }
          } else if (answered && state === 1) {
            resolve(handle);
          }
        } catch (_) {
          reject(signalingError());
        }
      }, 80);
      socket.connect(pairing.url).catch(unavailable);
    });
    accepted = true;
    return peer;
  } finally {
    clearInterval(timer);
    socket.close().catch((): void => {});
    if (!accepted && handle) releasePeer(handle);
  }
}
