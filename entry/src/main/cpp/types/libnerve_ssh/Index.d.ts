// 原生连接由句柄管理，ArkTS 不直接访问底层套接字。
export type SshHandle = Object;
export type PeerHandle = Object;

export interface SshEndpoint {
  host: string;
  port: number;
  peer?: PeerHandle;
}

export interface SshConnectOptions extends SshEndpoint {
  username: string;
  // 实际登录始终要求已确认的指纹。
  fingerprint: string;
  password: string;
  privateKey: string;
  passphrase: string;
  zellijSession: string;
  pushLink: string;
  discoverDaemon?: boolean;
  useMosh?: boolean;
  moshPort?: number;
  columns: number;
  rows: number;
}

// 只在启动 Mosh 协议引擎时取用一次，密钥仅在本次连接的内存中存在。
export interface SshMoshInfo {
  key: string;
  port: number;
}

// 只有登录前的主机密钥不匹配错误附带实际指纹。
export interface SshError extends Error {
  fingerprint?: string;
}

// 仅握手取指纹，不发起用户认证。
export const probeHostKey: (endpoint: SshEndpoint) => Promise<string>;
export const connect: (options: SshConnectOptions) => Promise<SshHandle>;
export const takeMoshInfo: (connection: SshHandle) => SshMoshInfo;
export const sendMoshDatagram: (connection: SshHandle, datagram: ArrayBuffer) => void;
export const rebindMosh: (connection: SshHandle) => void;
// 只交换 P2P 信令。SSH 主机指纹和 Mosh 密钥仍通过原来的连接取得。
export const createPeer: (stun: string) => PeerHandle;
export const peerOffer: (peer: PeerHandle) => string;
export const applyPeerAnswer: (peer: PeerHandle, sdp: string) => void;
export const peerState: (peer: PeerHandle) => number;
export const resumeP2pMosh: (connection: SshHandle, peer: PeerHandle) => void;
export const releasePeer: (peer: PeerHandle) => void;
// 返回这条已验证的 SSH 连接上读到的健康检查结果。
export const daemonHealth: (connection: SshHandle) => string;
// undefined 表示暂时无数据，空缓冲区表示远端结束。
export const read: (connection: SshHandle) => ArrayBuffer | undefined;
// 在读到远端 EOF 后读取 SSH 命令退出状态。
export const exitStatus: (connection: SshHandle) => number;
export const write: (connection: SshHandle, bytes: ArrayBuffer, offset: number) => number;
export const resize: (connection: SshHandle, columns: number, rows: number) => boolean;
export const disconnect: (connection: SshHandle) => void;
