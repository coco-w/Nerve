import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';

const TABLE = 'ssh_servers';
const SERVER_COLUMNS = ['id', 'alias', 'host', 'port', 'username', 'zellij_session', 'use_private_key', 'daemon_host_id',
  'use_mosh', 'mosh_port', 'p2p_endpoint'];
const CREDENTIAL_COLUMNS = ['password', 'private_key', 'passphrase', 'p2p_secret'];
// 由鸿蒙生成和保管加密数据库的密钥，数据库目录配置为不参与应用备份。
const STORE_CONFIG: relationalStore.StoreConfig = {
  name: 'servers.db',
  customDir: 'nerve_ssh',
  securityLevel: relationalStore.SecurityLevel.S4,
  encrypt: true
};

export interface SshServerSettings {
  // 别名用于显示，空字符串使用主机地址和端口作为标题。
  alias: string;
  host: string;
  port: number;
  username: string;
  zellijSession: string;
  usePrivateKey: boolean;
  useMosh: boolean;
  // 旧服务器默认使用 SSH，Mosh UDP 端口 0 表示由开发机分配。
  moshPort: number;
  // 只含 Gateway 地址和主机 ID，配对凭据按需读取。
  p2pEndpoint: string;
}

export interface SavedSshServer extends SshServerSettings {
  id: number;
  // 已通过本服务器的 SSH 连接确认的 Daemon ID，空字符串表示尚未绑定通知。
  daemonHostId: string;
}

export interface SshCredentials {
  password: string;
  privateKey: string;
  passphrase: string;
  p2pSecret?: string;
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
      alias TEXT NOT NULL DEFAULT '',
      host TEXT NOT NULL,
      port INTEGER NOT NULL,
      username TEXT NOT NULL,
      zellij_session TEXT NOT NULL,
      use_private_key INTEGER NOT NULL,
      password TEXT NOT NULL DEFAULT '',
      private_key TEXT NOT NULL DEFAULT '',
      passphrase TEXT NOT NULL DEFAULT '',
      daemon_host_id TEXT NOT NULL DEFAULT '',
      use_mosh INTEGER NOT NULL DEFAULT 0,
      mosh_port INTEGER NOT NULL DEFAULT 0,
      p2p_endpoint TEXT NOT NULL DEFAULT '',
      p2p_secret TEXT NOT NULL DEFAULT '',
      UNIQUE(host, port, username)
    )`);
    // 原地升级已有的加密库，保留服务器记录和 SSH 凭据。
    const columns = await db.querySql(`SELECT name FROM pragma_table_info('${TABLE}')`);
    const names = new Set<string>();
    try {
      while (columns.goToNextRow()) {
        names.add(columns.getString(0));
      }
    } finally {
      columns.close();
    }
    if (!names.has('daemon_host_id')) {
      await db.executeSql(`ALTER TABLE ${TABLE} ADD COLUMN daemon_host_id TEXT NOT NULL DEFAULT ''`);
    }
    if (!names.has('use_mosh')) {
      await db.executeSql(`ALTER TABLE ${TABLE} ADD COLUMN use_mosh INTEGER NOT NULL DEFAULT 0`);
    }
    if (!names.has('mosh_port')) {
      await db.executeSql(`ALTER TABLE ${TABLE} ADD COLUMN mosh_port INTEGER NOT NULL DEFAULT 0`);
    }
    if (!names.has('alias')) {
      // 老记录继承空别名，第一次打开新版即可继续按地址显示。
      await db.executeSql(`ALTER TABLE ${TABLE} ADD COLUMN alias TEXT NOT NULL DEFAULT ''`);
    }
    if (!names.has('p2p_endpoint')) {
      await db.executeSql(`ALTER TABLE ${TABLE} ADD COLUMN p2p_endpoint TEXT NOT NULL DEFAULT ''`);
    }
    if (!names.has('p2p_secret')) {
      await db.executeSql(`ALTER TABLE ${TABLE} ADD COLUMN p2p_secret TEXT NOT NULL DEFAULT ''`);
    }
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
          alias: rows.getString(rows.getColumnIndex('alias')),
          host: rows.getString(rows.getColumnIndex('host')),
          port: rows.getLong(rows.getColumnIndex('port')),
          username: rows.getString(rows.getColumnIndex('username')),
          zellijSession: rows.getString(rows.getColumnIndex('zellij_session')),
          usePrivateKey: rows.getLong(rows.getColumnIndex('use_private_key')) === 1,
          daemonHostId: rows.getString(rows.getColumnIndex('daemon_host_id')),
          useMosh: rows.getLong(rows.getColumnIndex('use_mosh')) === 1,
          moshPort: rows.getLong(rows.getColumnIndex('mosh_port')),
          p2pEndpoint: rows.getString(rows.getColumnIndex('p2p_endpoint'))
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
    const row = await db.query(this.matchingLogin(server.id, server).equalTo('p2p_endpoint', server.p2pEndpoint),
      CREDENTIAL_COLUMNS);
    try {
      if (!row.goToFirstRow()) {
        throw new Error('服务器配置已变化，请从列表重新选择。');
      }
      return {
        password: row.getString(0), privateKey: row.getString(1), passphrase: row.getString(2),
        p2pSecret: row.getString(3)
      };
    } finally {
      row.close();
    }
  }

  // 新增、更新各用一次数据库写入，服务器配置和凭据一起提交。
  async save(server: SshServerSettings, credentials: SshCredentials | undefined,
    previous?: SavedSshServer, pairingSecret?: string): Promise<SavedSshServer> {
    const db = await this.open();
    const values: relationalStore.ValuesBucket = {
      alias: server.alias,
      host: server.host,
      port: server.port,
      username: server.username,
      zellij_session: server.zellijSession,
      use_private_key: server.usePrivateKey ? 1 : 0,
      use_mosh: server.useMosh ? 1 : 0,
      mosh_port: server.moshPort,
      p2p_endpoint: server.p2pEndpoint
    };
    if (!server.p2pEndpoint || pairingSecret) {
      values['p2p_secret'] = pairingSecret ?? '';
    } else if (server.p2pEndpoint !== previous?.p2pEndpoint) {
      throw new Error('请填写完整的 P2P 配对地址。');
    }
    if (credentials) {
      values['password'] = credentials.password;
      values['private_key'] = credentials.privateKey;
      values['passphrase'] = credentials.passphrase;
    }
    let savedId: number;
    let daemonHostId = '';
    if (!previous) {
      if (!credentials) {
        throw new Error('新增服务器需要 SSH 凭据。');
      }
      savedId = await db.insert(TABLE, values);
      if (savedId < 1) {
        throw new Error('服务器记录写入失败。');
      }
    } else {
      // 更换 SSH 主机、端口或账号后，下一次连接重新查找该登录目标的 Daemon。
      if (previous.host === server.host && previous.port === server.port && previous.username === server.username) {
        daemonHostId = previous.daemonHostId;
      } else {
        values['daemon_host_id'] = '';
      }
      // 沿用凭据时限制在同一个登录目标，防止账号或主机变更时带入原凭据。
      const match = credentials ? this.matchingLogin(previous.id, previous) : this.matchingLogin(previous.id, server);
      if (await db.update(values, match.equalTo('p2p_endpoint', previous.p2pEndpoint)) !== 1) {
        throw new Error('服务器配置已变化，请重新编辑。');
      }
      savedId = previous.id;
    }
    return {
      id: savedId, alias: server.alias, host: server.host, port: server.port, username: server.username,
      zellijSession: server.zellijSession, usePrivateKey: server.usePrivateKey, daemonHostId,
      useMosh: server.useMosh, moshPort: server.moshPort, p2pEndpoint: server.p2pEndpoint
    };
  }

  async bindDaemonHost(server: SavedSshServer, daemonHostId: string): Promise<boolean> {
    const db = await this.open();
    // 连接过程中若配置被移除或已变更登录目标，丢弃迟到的绑定结果。
    const binding: relationalStore.ValuesBucket = { daemon_host_id: daemonHostId };
    return await db.update(binding, this.matchingLogin(server.id, server).equalTo('p2p_endpoint', server.p2pEndpoint)) === 1;
  }

  async remove(id: number): Promise<void> {
    const db = await this.open();
    await db.delete(new relationalStore.RdbPredicates(TABLE).equalTo('id', id));
  }
}
