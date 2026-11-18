import { request } from 'node:http';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';

export function nerveHome() {
  // NERVE_HOME 同时决定 Daemon 与适配器使用的本地数据目录。
  const directory = process.env.NERVE_HOME || join(homedir(), '.nerve');
  return resolve(directory);
}

export function requestJson(path: string, data?: unknown, timeoutMs = 2500): Promise<unknown> {
  const body = data === undefined ? undefined : JSON.stringify(data);
  return new Promise((resolve, reject) => {
    const req = request({
      socketPath: join(nerveHome(), 'nerve.sock'),
      path,
      method: body === undefined ? 'GET' : 'POST',
      headers: body === undefined ? undefined : {
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(body),
      },
      signal: AbortSignal.timeout(timeoutMs),
      agent: false,
    }, response => {
      response.setEncoding('utf8');
      let json = '';
      response.on('data', chunk => { json += chunk; });
      response.on('error', reject);
      response.on('end', () => {
        if (!response.statusCode || response.statusCode >= 400) {
          reject(new Error('Daemon 返回 HTTP ' + response.statusCode));
          return;
        }
        try {
          resolve(JSON.parse(json));
        } catch (error) {
          reject(error);
        }
      });
    });
    req.on('error', reject);
    req.end(body);
  });
}
