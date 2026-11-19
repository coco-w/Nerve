import { randomBytes, randomUUID } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import type { SQLOutputValue, StatementSync } from 'node:sqlite';
import type { AgentEvent } from './agent.js';
import { notificationFromEvent } from './notification.js';
import { PushQueue } from './push-queue.js';

export interface StoredEvent extends AgentEvent {
  hostId: string;
  sequence: number;
}

export class EventStore {
  readonly hostId: string;
  readonly pushQueue: PushQueue;
  private readonly db: DatabaseSync;
  private readonly insert: StatementSync;
  private readonly lookup: StatementSync;
  private readonly list: StatementSync;

  constructor(path: string, readonly pushEnabled = false) {
    this.db = new DatabaseSync(path, { timeout: 2500 });
    try {
      this.db.exec(
        'PRAGMA journal_mode = WAL;' +
        'CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;' +
        'CREATE TABLE IF NOT EXISTS agent_events (' +
        '  sequence INTEGER PRIMARY KEY,' +
        '  event_id TEXT NOT NULL UNIQUE,' +
        '  event_json TEXT NOT NULL' +
        ') STRICT;',
      );
      // 主机标识随库保存，Daemon 重启后仍指向同一台开发主机。
      this.db.prepare("INSERT INTO metadata VALUES ('host_id', ?) ON CONFLICT DO NOTHING").run(randomUUID());
      const host = this.db.prepare("SELECT value FROM metadata WHERE key = 'host_id'").get();
      if (typeof host?.value !== 'string') throw new Error('无法读取主机标识');
      this.hostId = host.value;
      this.insert = this.db.prepare(
        'INSERT INTO agent_events (event_id, event_json) VALUES (?, ?) ON CONFLICT(event_id) DO NOTHING',
      );
      this.lookup = this.db.prepare('SELECT sequence, event_json FROM agent_events WHERE event_id = ?');
      this.list = this.db.prepare('SELECT sequence, event_json FROM agent_events WHERE sequence > ? ORDER BY sequence LIMIT ?');
      this.pushQueue = new PushQueue(this.db);
    } catch (error) {
      this.db.close();
      throw error;
    }
  }

  p2pSecret(): string {
    // 配对码只通过用户私有的 Unix Socket 读取。Daemon 重启后保留原来的配对。
    this.db.prepare("INSERT INTO metadata VALUES ('p2p_secret', ?) ON CONFLICT DO NOTHING")
      .run(randomBytes(32).toString('base64url'));
    const row = this.db.prepare("SELECT value FROM metadata WHERE key = 'p2p_secret'").get();
    if (typeof row?.value !== 'string') throw new Error('无法读取 P2P 配对凭据');
    return row.value;
  }

  append(event: AgentEvent) {
    const json = JSON.stringify(event);
    // 新事件和待投递通知同一事务提交，Hook 的请求链路只访问本地 SQLite。
    const notification = this.pushEnabled ? notificationFromEvent(this.hostId, event) : undefined;
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const inserted = this.insert.run(event.eventId, json).changes === 1;
      const row = this.lookup.get(event.eventId);
      if (typeof row?.sequence !== 'number') throw new Error('无法读取已写入事件');
      if (inserted && notification && this.pushQueue.enqueue(notification) === 'conflict') {
        throw new Error('待投递通知标识冲突');
      }
      this.db.exec('COMMIT');
      return { sequence: row.sequence, inserted, conflict: row.event_json !== json };
    } catch (error) {
      if (this.db.isTransaction) this.db.exec('ROLLBACK');
      throw error;
    }
  }

  after(sequence: number, limit: number): StoredEvent[] {
    // 游标按写入顺序推进，可以读取时间戳较早但刚刚到达的事件。
    return this.list.all(sequence, limit).map(row => this.decodeEvent(row));
  }

  find(eventId: string): StoredEvent | undefined {
    const row = this.lookup.get(eventId);
    return row ? this.decodeEvent(row) : undefined;
  }

  private decodeEvent(row: Record<string, SQLOutputValue>): StoredEvent {
    return {
      ...JSON.parse(String(row.event_json)) as AgentEvent,
      sequence: Number(row.sequence),
      hostId: this.hostId,
    };
  }

  close() {
    this.db.close();
  }
}
