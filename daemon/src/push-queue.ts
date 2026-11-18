import type { DatabaseSync, StatementSync } from 'node:sqlite';
import type { PushNotification } from './notification.js';

export type PushOutcome = { state: 'sent' } | { state: 'retry' | 'failed'; code: string };
export type PushDelivery = (notification: PushNotification, signal: AbortSignal) => Promise<PushOutcome>;

interface Job {
  notification: PushNotification;
  attempt: number;
}

// 正常请求超时早于认领租约，重启后最长等待剩余租约时间即可重新投递。
const requestTimeoutMs = 5_000;
const leaseMs = 15_000;
const pollMs = 250;
const maxRetryMs = 300_000;

export class PushQueue {
  private readonly insert: StatementSync;
  private readonly lookup: StatementSync;
  private readonly take: StatementSync;
  private readonly update: StatementSync;
  private readonly count: StatementSync;

  constructor(db: DatabaseSync) {
    db.exec(`
      CREATE TABLE IF NOT EXISTS push_queue (
        host_id TEXT NOT NULL,
        event_id TEXT NOT NULL,
        payload TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'sent', 'failed')),
        ready_at INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        PRIMARY KEY (host_id, event_id)
      ) STRICT;
      CREATE INDEX IF NOT EXISTS push_queue_ready ON push_queue (ready_at, host_id, event_id)
        WHERE state = 'pending';
    `);
    this.insert = db.prepare(`
      INSERT INTO push_queue (host_id, event_id, payload, ready_at)
      VALUES (?, ?, ?, ?) ON CONFLICT(host_id, event_id) DO NOTHING
    `);
    this.lookup = db.prepare('SELECT payload FROM push_queue WHERE host_id = ? AND event_id = ?');
    // 在一条写语句里认领到期任务。进程中断时，任务在租约到期后可以被重新认领。
    this.take = db.prepare(`
      UPDATE push_queue SET ready_at = ?, attempts = attempts + 1
      WHERE (host_id, event_id) = (
        SELECT host_id, event_id FROM push_queue WHERE state = 'pending' AND ready_at <= ?
        ORDER BY ready_at, host_id, event_id LIMIT 1
      )
      RETURNING payload, attempts
    `);
    this.update = db.prepare(`
      UPDATE push_queue SET state = ?, ready_at = ?, last_error = ?
      WHERE host_id = ? AND event_id = ? AND state = 'pending' AND attempts = ?
    `);
    this.count = db.prepare('SELECT state, count(*) AS count FROM push_queue GROUP BY state');
  }

  enqueue(notification: PushNotification, now = Date.now()): 'inserted' | 'duplicate' | 'conflict' {
    const { hostId, eventId } = notification;
    const payload = JSON.stringify(notification);
    if (this.insert.run(hostId, eventId, payload, now).changes === 1) return 'inserted';
    return this.lookup.get(hostId, eventId)?.payload === payload ? 'duplicate' : 'conflict';
  }

  claim(now: number): Job | undefined {
    const row = this.take.get(now + leaseMs, now);
    if (row === undefined) return;
    return { notification: JSON.parse(String(row.payload)) as PushNotification, attempt: Number(row.attempts) };
  }

  finish(job: Job, outcome: PushOutcome, now: number) {
    const { hostId, eventId } = job.notification;
    const readyAt = outcome.state === 'retry' ? now + Math.min(maxRetryMs, 1000 * 2 ** Math.min(job.attempt - 1, 9)) : now;
    // 认领次数相当于版本号，过期请求的结果不能覆盖后来一次投递。
    this.update.run(outcome.state === 'retry' ? 'pending' : outcome.state, readyAt,
      outcome.state === 'sent' ? null : outcome.code, hostId, eventId, job.attempt);
  }

  status() {
    const counts = { pending: 0, sent: 0, failed: 0 };
    for (const row of this.count.all()) {
      if (row.state === 'pending' || row.state === 'sent' || row.state === 'failed') {
        counts[row.state] = Number(row.count);
      }
    }
    return counts;
  }
}

export function startPushWorker(queue: PushQueue, deliver: PushDelivery, label: string): () => void {
  const lifetime = new AbortController();
  let timer: NodeJS.Timeout;

  async function run() {
    let nextPoll = pollMs;
    try {
      const job = queue.claim(Date.now());
      if (!job) return;
      const signal = AbortSignal.any([lifetime.signal, AbortSignal.timeout(requestTimeoutMs)]);
      let outcome: PushOutcome;
      try {
        outcome = await deliver(job.notification, signal);
      } catch {
        outcome = { state: 'retry', code: signal.aborted ? 'request_timeout' : 'network_error' };
      }
      if (lifetime.signal.aborted) return;
      queue.finish(job, outcome, Date.now());
      if (outcome.state === 'failed' || (outcome.state === 'retry' && job.attempt === 1)) {
        console.error(label + ' 通知 ' + job.notification.eventId + ' 投递状态：' + outcome.code);
      }
      nextPoll = 0;
    } catch {
      console.error(label + ' 推送队列读写失败');
    } finally {
      if (!lifetime.signal.aborted) timer = setTimeout(run, nextPoll);
    }
  }

  timer = setTimeout(run, 0);
  return () => {
    clearTimeout(timer);
    lifetime.abort();
  };
}
