import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';

const TABLE = 'ssh_servers';
const SERVER_COLUMNS = ['id', 'host', 'port', 'username', 'zellij_session', 'use_private_key'];
const CREDENTIAL_COLUMNS = ['password', 'private_key', 'passphrase'];
// 由鸿蒙生成和保管加密数据库的密钥，数据库目录配置为不参与应用备份。
const STORE_CONFIG: relationalStore.StoreConfig = {
  name: 'servers.db',
  customDir: 'nerve_ssh',
  securityLevel: relationalStore.SecurityLevel.S4,
  encrypt: true
};

export interface SshServerSettings {
  host: string;
  port: number;
  username: string;
  zellijSession: string;
  usePrivateKey: boolean;
}

export interface SavedSshServer extends SshServerSettings {
  id: number;
}

export interface SshCredentials {
  password: string;
  privateKey: string;
  passphrase: string;
}

export class SshServerStore {
  private readonly context: common.Context;
  private database: Promise<relationalStore.RdbStore> | undefined;

  constructor(context: common.Context) {
    this.context = context;
  }

  private async initialize(): Promise<relationalStore.RdbStore> {
    const db = await relationalStore.getRdbStore(this.context, STORE_CONFIG);
    await db.executeSql(`CREATE TABLE IF NOT EXISTS ${TABLE} (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      host TEXT NOT NULL,
      port INTEGER NOT NULL,
      username TEXT NOT NULL,
      zellij_session TEXT NOT NULL,
      use_private_key INTEGER NOT NULL,
      password TEXT NOT NULL DEFAULT '',
      private_key TEXT NOT NULL DEFAULT '',
      passphrase TEXT NOT NULL DEFAULT '',
      UNIQUE(host, port, username)
    )`);
    return db;
  }

  private async open(): Promise<relationalStore.RdbStore> {
    if (!this.database) {
      this.database = this.initialize();
    }
    const opening = this.database;
    try {
      return await opening;
    } catch (_) {
      if (this.database === opening) {
        this.database = undefined;
      }
      throw new Error('无法打开 SSH 服务器存储。');
    }
  }

  // 列表和编辑页只读取连接信息，登录时才按选中的服务器单独读取凭据。
  async list(): Promise<SavedSshServer[]> {
    const db = await this.open();
    const rows = await db.query(new relationalStore.RdbPredicates(TABLE).orderByDesc('id'), SERVER_COLUMNS);
    try {
      const servers: SavedSshServer[] = [];
      while (rows.goToNextRow()) {
        servers.push({
          id: rows.getLong(rows.getColumnIndex('id')),
          host: rows.getString(rows.getColumnIndex('host')),
          port: rows.getLong(rows.getColumnIndex('port')),
          username: rows.getString(rows.getColumnIndex('username')),
          zellijSession: rows.getString(rows.getColumnIndex('zellij_session')),
          usePrivateKey: rows.getLong(rows.getColumnIndex('use_private_key')) === 1
        });
      }
      return servers;
    } finally {
      rows.close();
    }
  }

  private matchingLogin(id: number, server: SshServerSettings): relationalStore.RdbPredicates {
    return new relationalStore.RdbPredicates(TABLE).equalTo('id', id).equalTo('host', server.host)
      .equalTo('port', server.port).equalTo('username', server.username)
      .equalTo('use_private_key', server.usePrivateKey ? 1 : 0);
  }

  async credentials(server: SavedSshServer): Promise<SshCredentials> {
    const db = await this.open();
    const row = await db.query(this.matchingLogin(server.id, server), CREDENTIAL_COLUMNS);
    try {
      if (!row.goToFirstRow()) {
        throw new Error('服务器配置已变化，请从列表重新选择。');
      }
      return {
        password: row.getString(0), privateKey: row.getString(1), passphrase: row.getString(2)
      };
    } finally {
      row.close();
    }
  }

  // 新增、更新各用一次数据库写入，服务器配置和凭据一起提交。
  async save(server: SshServerSettings, credentials: SshCredentials | undefined, id?: number): Promise<SavedSshServer> {
    const db = await this.open();
    const values: relationalStore.ValuesBucket = {
      host: server.host,
      port: server.port,
      username: server.username,
      zellij_session: server.zellijSession,
      use_private_key: server.usePrivateKey ? 1 : 0
    };
    if (credentials) {
      values['password'] = credentials.password;
      values['private_key'] = credentials.privateKey;
      values['passphrase'] = credentials.passphrase;
    }
    let savedId: number;
    if (id === undefined) {
      if (!credentials) {
        throw new Error('新增服务器需要 SSH 凭据。');
      }
      savedId = await db.insert(TABLE, values);
      if (savedId < 1) {
        throw new Error('服务器记录写入失败。');
      }
    } else {
      // 沿用凭据时限制在同一个登录目标，防止账号或主机变更时带入原凭据。
      const match = credentials ? new relationalStore.RdbPredicates(TABLE).equalTo('id', id) :
        this.matchingLogin(id, server);
      if (await db.update(values, match) !== 1) {
        throw new Error('服务器配置已变化，请重新编辑。');
      }
      savedId = id;
    }
    return {
      id: savedId, host: server.host, port: server.port, username: server.username,
      zellijSession: server.zellijSession, usePrivateKey: server.usePrivateKey
    };
  }

  async remove(id: number): Promise<void> {
    const db = await this.open();
    await db.delete(new relationalStore.RdbPredicates(TABLE).equalTo('id', id));
  }
}
