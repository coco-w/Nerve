import { randomUUID } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import type { StatementSync } from 'node:sqlite';
import type { AgentEvent } from './agent.js';

export interface StoredEvent extends AgentEvent {
  hostId: string;
  sequence: number;
}

export class EventStore {
  readonly hostId: string;
  private readonly db: DatabaseSync;
  private readonly insert: StatementSync;
  private readonly lookup: StatementSync;
  private readonly list: StatementSync;

  constructor(path: string) {
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
    } catch (error) {
      this.db.close();
      throw error;
    }
  }

  append(event: AgentEvent) {
    const json = JSON.stringify(event);
    // 唯一约束保证并发写入和同 ID 重试只落一条记录。
    const result = this.insert.run(event.eventId, json);
    const row = this.lookup.get(event.eventId);
    if (typeof row?.sequence !== 'number') throw new Error('无法读取已写入事件');
    return { sequence: row.sequence, inserted: result.changes === 1, conflict: row.event_json !== json };
  }

  after(sequence: number, limit: number): StoredEvent[] {
    // 游标按写入顺序推进，可以读取时间戳较早但刚刚到达的事件。
    return this.list.all(sequence, limit).map(row => ({
      ...JSON.parse(String(row.event_json)) as AgentEvent,
      sequence: Number(row.sequence),
      hostId: this.hostId,
    }));
  }

  close() {
    this.db.close();
  }
}
