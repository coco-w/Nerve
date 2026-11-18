// 原生连接由句柄管理，ArkTS 不直接访问底层套接字。
export type SshHandle = Object;

export interface SshConnectOptions {
  host: string;
  port: number;
  username: string;
  fingerprint: string;
  password: string;
  privateKey: string;
  passphrase: string;
  zellijSession: string;
  columns: number;
  rows: number;
}

export const connect: (options: SshConnectOptions) => Promise<SshHandle>;
// undefined 表示暂时无数据，空缓冲区表示远端结束。
export const read: (connection: SshHandle) => ArrayBuffer | undefined;
export const write: (connection: SshHandle, bytes: ArrayBuffer, offset: number) => number;
export const resize: (connection: SshHandle, columns: number, rows: number) => boolean;
export const disconnect: (connection: SshHandle) => void;
