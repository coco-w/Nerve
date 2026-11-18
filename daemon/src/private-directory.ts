import { lstatSync, mkdirSync } from 'node:fs';

export function ensurePrivateDirectory(directory: string, setting: string) {
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const stat = lstatSync(directory);
  // 两个服务各用独立的私有目录保存 SQLite，避免跨系统用户读取。
  if (!stat.isDirectory() || stat.uid !== process.getuid?.() || (stat.mode & 0o077) !== 0) {
    throw new Error(setting + ' 必须是当前用户拥有的私有目录（权限 0700）');
  }
}
