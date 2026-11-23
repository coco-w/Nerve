import { webview } from '@kit.ArkWeb';
import { preferences } from '@kit.ArkData';
import { KeyboardAvoidMode, window } from '@kit.ArkUI';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { connect, daemonHealth, disconnect, exitStatus, PeerHandle, probeHostKey, read, rebindMosh, releasePeer, resize,
  resumeP2pMosh, sendMoshDatagram, SshConnectOptions, SshError, SshHandle, takeMoshInfo, write } from 'libnerve_ssh.so';
import { hostIdFromDaemonHealth } from '../push/PushLink';
import { PushSettings } from '../push/PushSettings';
import { dialP2p, P2pPairing, parseP2pPairing } from '../ssh/P2pClient';
import { SavedSshServer, SshCredentials, SshServerSettings, SshServerStore } from '../ssh/SshServerStore';
import { NerveTerminalMenu, NERVE_TERMINAL_MENU_BACKGROUND } from '../ui/TerminalMenu';
import { APP_FONT, nerveColors, NerveColors, PALETTES, TERMINAL_BACKGROUND, TERMINAL_MUTED, TERMINAL_SURFACE,
  TERMINAL_TEXT, ThemePalette } from '../ui/Theme';

// ArkWeb 拦截时使用资源 URL，加载后可能显示为 RAWFILE 格式。
const TERMINAL_URL = 'resource://rawfile/terminal/index.html';
const TERMINAL_LOADED_URL = 'resource:/RAWFILE/terminal/index.html';
const TERMINAL_FILE_URL = 'file:///data/storage/el1/bundle/entry/resources/rawfile/terminal/index.html';
// 终端工具栏和底部手势区共用底色。
const TERMINAL_TOOLBAR_BACKGROUND = '#171b2a';
const POLL_MS = 30;
const MAX_CHUNK_BYTES = 16 * 1024;
const MAX_QUEUED_BYTES = 64 * 1024;
const MAX_KEY_BYTES = 32 * 1024;
const MOSH_WASM_CHUNK = 64 * 1024;
const MOSH_READ_BATCH = 24;
const MOSH_MAX_ENCODED_PACKET = 2732;
const MOSH_CLOSE_MS = 1500;
// nerve attach-event 用此状态报告原 Zellij 会话已关闭。
const SESSION_UNAVAILABLE_EXIT_STATUS = 20;
// 应用本地的 SSH 信任记录，按主机和端口保存指纹。
const KNOWN_HOSTS_STORE = 'nerve_known_hosts';
const UI_STORE = 'nerve_ui';
const RECENT_LIMIT = 8;

interface RecentSession {
  serverId: number;
  openedAt: number;
}

interface PtySize {
  columns: number;
  rows: number;
}

interface HostKeyReview {
  host: string;
  port: number;
  observed: string;
  previous: string;
  reconnect: boolean;
}

interface SshOpenRequest {
  options: SshConnectOptions;
  server?: SavedSshServer;
  pairing?: P2pPairing;
}

interface NerveOptionButtonParams {
  label: string;
  selected: boolean;
  onSelect: () => void;
}

interface MoshBridgeCallbacks {
  wasm: (offset: number) => string;
  key: () => string;
  datagram: (encoded: string) => void;
  rebind: () => void;
  state: (status: string) => void;
}

// 由内置 Web 终端调用。SSH 凭据留在应用，Mosh 引擎只取一次临时会话密钥。
class TerminalBridge {
  private readonly input: (text: string) => void;
  private readonly binaryInput: (encoded: string) => void;
  private readonly size: (columns: number, rows: number) => void;
  private readonly outputFlushed: () => void;
  private readonly mosh: MoshBridgeCallbacks;

  constructor(input: (text: string) => void, binaryInput: (encoded: string) => void,
    size: (columns: number, rows: number) => void, outputFlushed: () => void, mosh: MoshBridgeCallbacks) {
    this.input = input;
    this.binaryInput = binaryInput;
    this.size = size;
    this.outputFlushed = outputFlushed;
    this.mosh = mosh;
  }

  onInput(text: string): void {
    this.input(text);
  }

  onBinary(encoded: string): void {
    this.binaryInput(encoded);
  }

  onSize(columns: number, rows: number): void {
    this.size(columns, rows);
  }

  onOutputFlushed(): void {
    this.outputFlushed();
  }

  onMoshWasm(offset: number): string {
    return this.mosh.wasm(offset);
  }

  onMoshKey(): string {
    return this.mosh.key();
  }

  onMoshDatagram(encoded: string): void {
    this.mosh.datagram(encoded);
  }

  onMoshRebind(): void {
    this.mosh.rebind();
  }

  onMoshState(status: string): void {
    this.mosh.state(status);
  }
}

@Entry
@Component
struct Index {
  @StorageProp('nervePushLink') @Watch('onPushLinkChanged') private pushLink: string = '';
  @StorageProp('nerveKeyboardHeight') @Watch('onKeyboardHeightChanged') private keyboardHeight: number = 0;
  @State private activeTab: number = 0;
  @State private utilityPage: string = 'settings';
  @State private utilityVisible: boolean = false;
  @State private pushSettingsVisible: boolean = false;
  @State private darkAppearance: boolean = false;
  @State private colors: NerveColors = nerveColors('indigo', false);
  @State private preferenceError: string = '';
  @State private recentSessions: RecentSession[] = [];
  @State private pickingNotificationHost: boolean = false;
  @State private pairedConnection: boolean = false;
  @State private advancedConnection: boolean = false;
  @State private terminalKeysVisible: boolean = false;
  @State private terminalEnded: boolean = false;
  @State private terminalServerId: number = 0;
  @State private openedHostLabel: string = '';
  @State private openedPushLink: string = '';
  @State private openedRemoteTitle: string = '';
  @State @Watch('updateNotificationMatch') private savedServers: SavedSshServer[] = [];
  @State private notificationServer: SavedSshServer | undefined = undefined;
  @State private editingServer: SavedSshServer | undefined = undefined;
  @State private serverEditorOpen: boolean = false;
  @State private managingServers: boolean = false;
  @State private serverListUnavailable: boolean = false;
  @State private serverAlias: string = '';
  @State private host: string = '';
  @State private p2pCode: string = '';
  @State private port: string = '22';
  @State private username: string = '';
  @State private zellijSession: string = '';
  @State private useMosh: boolean = false;
  @State private moshPortInput: string = '';
  @State private usePrivateKey: boolean = false;
  @State private keySelected: boolean = false;
  @State private password: string = '';
  @State private passphrase: string = '';
  @State private checkingHostKey: boolean = false;
  @State private hostKeyReview: HostKeyReview | undefined = undefined;
  @State @Watch('syncSystemBars') private terminalVisible: boolean = false;
  @State private terminalInstance: number = 0;
  // 终端菜单独立于首页设置弹层，关闭菜单时保留当前连接。
  @State private terminalMenuVisible: boolean = false;
  @State private connected: boolean = false;
  @State private closingMosh: boolean = false;
  @State private statusText: string = '';
  @State private errorText: string = '';
  @State private ctrlArmed: boolean = false;

  private privateKey: string = '';
  private serverStore: SshServerStore | undefined;
  private uiPreferences: preferences.Preferences | undefined;
  private preferenceWrite: Promise<void> = Promise.resolve();
  private recentServerId: number = 0;
  private formKeyboardMode: KeyboardAvoidMode = KeyboardAvoidMode.OFFSET;
  private view = new webview.WebviewController();
  private readonly encoder = new util.TextEncoder();
  private readonly base64 = new util.Base64Helper();
  private bridge = this.createBridge(0);

  // 连接代次会在退出时增加，丢弃此前未完成的握手和渲染回调。
  private generation: number = 0;
  private connection: SshHandle | undefined;
  private p2pSession: P2pPairing | undefined;
  private reconnectingP2p: boolean = false;
  private moshActive: boolean = false;
  private moshPort: number = 0;
  private moshWasm: Uint8Array | undefined;
  private moshPumpPending: boolean = false;
  private moshCloseTimer: number = -1;
  private afterMoshClose: (() => void) | undefined;
  // 等待确认或终端准备时，已保存的服务器只携带配置，不提前读取凭据。
  private pendingTrustConnection: SshOpenRequest | undefined;
  private pendingConnection: SshOpenRequest | undefined;
  private loadTimer: number = -1;
  private ioTimer: number = -1;
  private inputQueue: Array<ArrayBuffer> = [];
  private inputOffset: number = 0;
  private queuedBytes: number = 0;
  private writePending: boolean = false;
  private renderPending: boolean = false;
  private receivedTerminalOutput: boolean = false;
  private latestSize: PtySize = { columns: 80, rows: 24 };
  private sentSize: PtySize = { columns: 80, rows: 24 };
  private resizePending: PtySize | undefined;

  aboutToAppear(): void {
    this.getUIContext().getFont().registerFont({
      familyName: APP_FONT,
      familySrc: $rawfile('fonts/MapleMono-NF-CN-Regular.ttf')
    });
    this.loadUiPreferences();
    this.loadSavedServers();
  }

  onPageShow(): void {
    this.syncSystemBars();
  }

  private syncSystemBars(): void {
    const context = this.getUIContext().getHostContext();
    if (!context) return;
    window.getLastWindow(context).then((mainWindow: window.Window): Promise<void> => {
      // 取得窗口后再读取主题和页面状态，快速切换时使用当前颜色。
      const top = this.terminalVisible ? TERMINAL_BACKGROUND : this.colors.background;
      const bottom = this.terminalVisible ? TERMINAL_TOOLBAR_BACKGROUND : this.colors.background;
      const foreground = this.terminalVisible ? TERMINAL_TEXT : this.colors.foreground;
      // 底部手势区绘制在窗口背景上，状态栏另行使用顶部底色。
      mainWindow.setWindowBackgroundColor(bottom);
      return mainWindow.setWindowSystemBarProperties({
        statusBarColor: top,
        navigationBarColor: bottom,
        statusBarContentColor: foreground,
        navigationBarContentColor: foreground
      });
    }).catch(() => {
      // 窗口切换期间可能暂时不可用，页面再次显示时会重试。
    });
  }

  private loadUiPreferences(): void {
    const context = this.getUIContext().getHostContext();
    if (!context) return;
    try {
      const store = preferences.getPreferencesSync(context, { name: UI_STORE });
      this.uiPreferences = store;
      this.darkAppearance = store.getSync('dark', false) === true;
      this.colors = nerveColors(String(store.getSync('palette', 'indigo')), this.darkAppearance);
      const recent = JSON.parse(String(store.getSync('recent', '[]'))) as RecentSession[];
      if (Array.isArray(recent)) {
        this.recentSessions = recent.filter((item: RecentSession): boolean =>
          !!item && Number.isInteger(item.serverId) && item.serverId > 0 &&
          Number.isFinite(item.openedAt) && item.openedAt > 0).slice(0, RECENT_LIMIT);
      }
    } catch (_) {
      // 保留已经读取的外观，其余界面可在没有历史记录时正常打开。
    }
  }

  private persistUiPreferences(appearance: boolean): void {
    const store = this.uiPreferences;
    if (!store) {
      if (appearance) this.preferenceError = '暂时无法保存外观设置。';
      return;
    }
    try {
      if (appearance) {
        this.preferenceError = '';
        store.putSync('dark', this.darkAppearance);
        store.putSync('palette', this.colors.palette.id);
      } else {
        store.putSync('recent', JSON.stringify(this.recentSessions));
      }
      this.preferenceWrite = this.preferenceWrite.then(() => store.flush()).catch(() => {
        if (appearance) this.preferenceError = '无法保存外观设置，请重试。';
      });
    } catch (_) {
      if (appearance) this.preferenceError = '无法保存外观设置，请重试。';
    }
  }

  private changeAppearance(palette: string, dark: boolean): void {
    this.darkAppearance = dark;
    this.colors = nerveColors(palette, dark);
    this.syncSystemBars();
    this.persistUiPreferences(true);
  }

  private rememberRecentConnection(): void {
    const id = this.recentServerId;
    if (!id) return;
    this.recentServerId = 0;
    const recent: RecentSession = { serverId: id, openedAt: Date.now() };
    this.recentSessions = [recent,
      ...this.recentSessions.filter((item: RecentSession): boolean => item.serverId !== id)].slice(0, RECENT_LIMIT);
    this.persistUiPreferences(false);
  }

  private forgetRecentConnection(id: number): void {
    if (this.recentSessions.some((item: RecentSession): boolean => item.serverId === id)) {
      this.recentSessions = this.recentSessions.filter((item: RecentSession): boolean => item.serverId !== id);
      this.persistUiPreferences(false);
    }
  }

  private showUtility(page: string): void {
    this.utilityPage = page;
    this.utilityVisible = true;
  }

  onBackPress(): boolean {
    if (this.terminalMenuVisible) {
      this.terminalMenuVisible = false;
      return true;
    }
    if (this.utilityVisible) {
      this.utilityVisible = false;
      return true;
    }
    if (this.hostKeyReview) {
      this.cancelHostKeyReview();
      return true;
    }
    if (this.checkingHostKey) {
      this.generation++;
      this.checkingHostKey = false;
      return true;
    }
    if (this.pushSettingsVisible) {
      this.pushSettingsVisible = false;
      return true;
    }
    if (this.terminalVisible) {
      this.closeTerminal(() => this.backToForm());
      return true;
    }
    if (this.managingServers) {
      return true;
    }
    if (this.serverEditorOpen) {
      this.setServerEditor(false);
      return true;
    }
    if (this.pickingNotificationHost) {
      this.pickingNotificationHost = false;
      return true;
    }
    if (this.activeTab !== 0) {
      this.changeTab(0);
      return true;
    }
    return false;
  }

  private onPushLinkChanged(): void {
    this.pickingNotificationHost = false;
    if (this.pushLink) {
      this.pushSettingsVisible = false;
      if (this.utilityPage === 'settings') this.utilityVisible = false;
    }
    this.updateNotificationMatch();
  }

  private updateNotificationMatch(): void {
    const daemonHostId = this.pushLink.slice(0, 36);
    // 同一 Daemon 有多个 SSH 登录方式时保留手选入口，避免猜测用户希望使用哪条连接。
    const matches = daemonHostId ? this.savedServers.filter((server: SavedSshServer): boolean =>
      server.daemonHostId === daemonHostId) : [];
    this.notificationServer = matches.length === 1 ? matches[0] : undefined;
  }

  private openMatchedNotification(): void {
    const server = this.notificationServer;
    const link = this.pushLink;
    if (!server || !link || this.managingServers || this.checkingHostKey) {
      return;
    }
    this.followNotification(() => this.startConnection(server, link));
  }

  private async followNotification(open: () => void): Promise<void> {
    const link = this.pushLink;
    this.utilityVisible = false;
    if (this.terminalVisible) {
      if (!this.terminalEnded) {
        const generation = this.generation;
        try {
          const result = await this.getUIContext().getPromptAction().showDialog({
            title: '切换会话？',
            message: '将断开当前手机连接。远端 Zellij 会话会继续运行。',
            buttons: [{ text: '取消', color: this.colors.muted }, { text: '继续', color: this.colors.accent }]
          });
          if (result.index !== 1 || generation !== this.generation || link !== this.pushLink) return;
        } catch (_) {
          return;
        }
      }
      this.closeTerminal(() => {
        this.backToForm();
        if (link === this.pushLink) open();
      });
    } else {
      open();
    }
  }

  private chooseNotificationHost(): void {
    this.followNotification(() => {
      this.changeTab(1);
      this.pickingNotificationHost = true;
    });
  }

  private changeTab(tab: number): void {
    this.activeTab = tab;
    this.errorText = '';
    if (tab === 0) this.pickingNotificationHost = false;
  }

  private useSavedServer(id: number, edit: boolean): void {
    // 列表行用稳定 ID 复用，操作时读取最新配置和通知绑定。
    const server = this.savedServers.find((item: SavedSshServer): boolean => item.id === id);
    if (!server) {
      return;
    }
    if (edit) {
      this.setServerEditor(true, server);
    } else {
      this.startConnection(server, this.pickingNotificationHost ? this.pushLink : '');
    }
  }

  aboutToDisappear(): void {
    if (this.terminalVisible) {
      this.getUIContext().setKeyboardAvoidMode(this.formKeyboardMode);
    }
    this.stopConnection();
    this.pendingTrustConnection = undefined;
    this.hostKeyReview = undefined;
    this.checkingHostKey = false;
    this.clearCredentials();
  }

  private clearCredentials(): void {
    this.password = '';
    this.privateKey = '';
    this.passphrase = '';
    this.keySelected = false;
  }

  private savedServerStore(): SshServerStore {
    if (!this.serverStore) {
      const context = this.getUIContext().getHostContext();
      if (!context) {
        throw new Error('无法访问已保存的服务器。');
      }
      this.serverStore = new SshServerStore(context);
    }
    return this.serverStore;
  }

  private async loadSavedServers(): Promise<void> {
    this.managingServers = true;
    try {
      this.savedServers = await this.savedServerStore().list();
      this.serverListUnavailable = false;
    } catch (_) {
      this.serverListUnavailable = true;
    } finally {
      this.managingServers = false;
    }
  }

  private setServerEditor(isOpen: boolean, server?: SavedSshServer): void {
    this.generation++;
    this.clearCredentials();
    this.errorText = '';
    this.editingServer = server;
    this.serverAlias = server?.alias ?? '';
    this.host = server?.p2pEndpoint ? '' : server?.host ?? '';
    this.p2pCode = server?.p2pEndpoint ?? '';
    this.pairedConnection = !!server?.p2pEndpoint;
    this.advancedConnection = !!server?.moshPort;
    this.port = server ? String(server.port) : '22';
    this.username = server?.username ?? '';
    this.zellijSession = server?.zellijSession ?? '';
    this.useMosh = server?.useMosh ?? false;
    this.moshPortInput = server?.moshPort ? String(server.moshPort) : '';
    this.usePrivateKey = server?.usePrivateKey ?? false;
    this.serverEditorOpen = isOpen;
  }

  private usePairedConnection(paired: boolean): void {
    if (this.pairedConnection === paired) return;
    this.pairedConnection = paired;
    this.p2pCode = paired ? this.editingServer?.p2pEndpoint ?? '' : '';
    this.advancedConnection = false;
    this.errorText = '';
  }

  private formHost(): string {
    const pairing = parseP2pPairing(this.p2pCode);
    if (pairing) return pairing.hostId;
    const host = this.host.trim().replace(/^\[([^\]]+)\]$/, '$1');
    return host.includes(':') ? host : host.toLowerCase();
  }

  private formSettings(useSession: boolean): SshServerSettings | undefined {
    const pairing = parseP2pPairing(this.p2pCode);
    if (this.pairedConnection && !pairing) {
      this.errorText = '请粘贴 nerve pair 输出的 P2P 配对地址。';
      return undefined;
    }
    const host = this.formHost();
    const username = this.username.trim();
    const port = pairing ? 22 : Number(this.port);
    const zellijSession = useSession ? this.zellijSession.trim() : '';
    if (!host || !username || (!pairing && !/^\d{1,5}$/.test(this.port)) || port < 1 || port > 65535) {
      this.errorText = '请填写主机地址、用户名和 1–65535 范围内的端口。';
      return undefined;
    }
    if (this.encoder.encodeInto(host).length > 253 || this.encoder.encodeInto(username).length > 256 ||
      host.includes('\u0000') || username.includes('\u0000')) {
      this.errorText = '主机地址或用户名不符合 SSH 连接要求。';
      return undefined;
    }
    if (zellijSession && !/^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/.test(zellijSession)) {
      this.errorText = '会话名可使用字母、数字、下划线、点和连字符。留空后可在终端中手动附接。';
      return undefined;
    }
    const udpPort = this.useMosh && !pairing ? this.moshPortInput.trim() : '';
    const moshPort = udpPort ? Number(udpPort) : 0;
    if (udpPort && (!/^\d{1,5}$/.test(udpPort) || moshPort < 1 || moshPort > 65535)) {
      this.errorText = 'Mosh UDP 端口应为 1–65535，留空使用开发机分配的端口。';
      return undefined;
    }
    // 只输入空白字符等同于留空，连接身份仍使用实际主机与账号。
    return {
      alias: this.serverAlias.trim(), host, port, username, zellijSession,
      usePrivateKey: this.usePrivateKey, useMosh: this.useMosh, moshPort,
      p2pEndpoint: pairing ? pairing.url + '#' + pairing.hostId : ''
    };
  }

  private formCredentials(): SshCredentials | undefined {
    if (this.usePrivateKey ? !this.keySelected : !this.password) {
      return undefined;
    }
    return { password: this.password, privateKey: this.privateKey, passphrase: this.passphrase };
  }

  private canKeepSavedCredentials(): boolean {
    const server = this.editingServer;
    const port = parseP2pPairing(this.p2pCode) ? 22 : Number(this.port);
    return server !== undefined && server.host === this.formHost() && server.port === port &&
      server.username === this.username.trim() && server.usePrivateKey === this.usePrivateKey;
  }

  private async saveServer(): Promise<void> {
    const server = this.formSettings(true);
    if (!server || this.managingServers) {
      return;
    }
    const credentials = this.formCredentials();
    if (!credentials && !this.canKeepSavedCredentials()) {
      this.errorText = server.usePrivateKey ? '请选择 SSH 私钥。' : '请输入 SSH 密码。';
      return;
    }
    const editing = this.editingServer;
    const secret = parseP2pPairing(this.p2pCode)?.secret;
    if (server.p2pEndpoint && server.p2pEndpoint !== editing?.p2pEndpoint && !secret) {
      this.errorText = '请粘贴含有效凭据的完整 P2P 配对地址。';
      return;
    }
    const editingId = editing?.id;
    this.managingServers = true;
    this.errorText = '';
    try {
      const storage = this.savedServerStore();
      if (this.serverListUnavailable) {
        this.savedServers = await storage.list();
        this.serverListUnavailable = false;
      }
      if (this.savedServers.some((item: SavedSshServer): boolean => item.id !== editingId &&
        item.host === server.host && item.port === server.port && item.username === server.username)) {
        this.errorText = '该服务器账号已保存，请在列表中编辑。';
        return;
      }
      const saved = await storage.save(server, credentials, editing, secret || undefined);
      this.savedServers = editingId === undefined ? [saved, ...this.savedServers] :
        this.savedServers.map((item: SavedSshServer): SavedSshServer => item.id === saved.id ? saved : item);
      if (editing && (saved.host !== editing.host || saved.port !== editing.port || saved.username !== editing.username ||
        saved.zellijSession !== editing.zellijSession || saved.p2pEndpoint !== editing.p2pEndpoint)) {
        this.forgetRecentConnection(saved.id);
      }
      this.setServerEditor(false);
    } catch (_) {
      this.errorText = '无法保存服务器，请重试。';
    } finally {
      this.managingServers = false;
    }
  }

  private async removeServer(): Promise<void> {
    const server = this.editingServer;
    if (!server || this.managingServers) {
      return;
    }
    const generation = this.generation;
    try {
      const result = await this.getUIContext().getPromptAction().showDialog({
        title: '删除服务器',
        message: '将从此设备移除该服务器的配置和 SSH 凭据。',
        buttons: [{ text: '取消', color: '#565d62' }, { text: '删除', color: '#b3261e' }]
      });
      if (result.index !== 1 || this.generation !== generation) {
        return;
      }
    } catch (_) {
      return;
    }
    this.managingServers = true;
    try {
      await this.savedServerStore().remove(server.id);
      this.savedServers = this.savedServers.filter((item: SavedSshServer): boolean => item.id !== server.id);
      this.forgetRecentConnection(server.id);
      this.setServerEditor(false);
    } catch (_) {
      this.errorText = '无法删除服务器，请重试。';
    } finally {
      this.managingServers = false;
    }
  }

  private changeAuth(usePrivateKey: boolean): void {
    if (this.usePrivateKey !== usePrivateKey) {
      this.clearCredentials();
      this.usePrivateKey = usePrivateKey;
      this.errorText = '';
    }
  }

  private async selectKey(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (!context) {
      return;
    }
    const generation = this.generation;
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      const uris = await new picker.DocumentViewPicker(context).select(options);
      if (!uris.length || !this.usePrivateKey || this.generation !== generation) {
        return;
      }
      // 文件选择器提供 URI，以文件描述符限量读取，无需复制到应用目录。
      const file = await fileIo.open(uris[0], fileIo.OpenMode.READ_ONLY);
      let content = '';
      try {
        const data = new ArrayBuffer(MAX_KEY_BYTES + 1);
        const size = await fileIo.read(file.fd, data);
        if (size <= MAX_KEY_BYTES) {
          content = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(data, 0, size));
        }
      } finally {
        await fileIo.close(file);
      }
      if (!this.usePrivateKey || this.generation !== generation) {
        return;
      }
      if (!/^-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/.test(content)) {
        this.errorText = '请选择有效的 OpenSSH 或 PEM 私钥文件。';
        return;
      }
      this.privateKey = content.replace(/\r\n/g, '\n');
      this.keySelected = true;
      this.errorText = '';
    } catch (_) {
      if (this.generation === generation) {
        this.errorText = '无法读取所选的私钥文件。';
      }
    }
  }

  private knownHostId(host: string, port: number): string {
    // DNS 大小写共用信任记录，IPv6 保留接口作用域名称。
    return host.includes(':') ? `[${host}]:${port}` : `${host.toLowerCase()}:${port}`;
  }

  private async openKnownHosts(): Promise<preferences.Preferences> {
    const context = this.getUIContext().getHostContext();
    if (!context) {
      throw new Error('无法访问本机的 SSH 信任记录。');
    }
    try {
      return await preferences.getPreferences(context, { name: KNOWN_HOSTS_STORE });
    } catch (_) {
      throw new Error('无法打开本机的 SSH 信任记录。');
    }
  }

  private startConnection(server?: SavedSshServer, pushLink: string = ''): void {
    if (this.terminalVisible || this.hostKeyReview || this.checkingHostKey || this.managingServers) {
      return;
    }
    // 通知只引用本地事件，通过已校验指纹的 SSH 连接到对应开发机后才解析会话。
    const settings = server ?? this.formSettings(!pushLink);
    if (!settings) {
      return;
    }
    const credentials = server ? undefined : this.formCredentials();
    if (!server && !credentials) {
      this.errorText = settings.usePrivateKey ? '请选择 SSH 私钥。' : '请输入 SSH 密码。';
      return;
    }
    const options: SshConnectOptions = {
      host: settings.host, port: settings.port, username: settings.username, fingerprint: '',
      password: credentials?.password ?? '', privateKey: credentials?.privateKey ?? '',
      passphrase: credentials?.passphrase ?? '', zellijSession: pushLink ? '' : settings.zellijSession,
      pushLink, columns: 80, rows: 24, useMosh: settings.useMosh, moshPort: settings.moshPort,
      // 已匹配的通知由 attach-event 再校验主机，普通连接和手动选择会刷新绑定。
      discoverDaemon: server !== undefined && (!pushLink || server.daemonHostId !== pushLink.slice(0, 36))
    };
    const pairing = parseP2pPairing(server ? server.p2pEndpoint : this.p2pCode);
    this.prepareConnection({ options, server, pairing });
  }

  private async openPeer(request: SshOpenRequest, generation: number): Promise<PeerHandle | undefined> {
    const pairing = request.pairing;
    if (!pairing) return undefined;
    if (!pairing.secret && request.server) {
      pairing.secret = (await this.savedServerStore().credentials(request.server)).p2pSecret ?? '';
    }
    if (!pairing.secret) throw new Error('请补全 P2P 配对地址。');
    return dialP2p(pairing, (): boolean => this.generation === generation);
  }

  private async prepareConnection(request: SshOpenRequest): Promise<void> {
    const options = request.options;
    const host = options.host;
    const port = options.port;
    const generation = ++this.generation;
    this.checkingHostKey = true;
    this.errorText = '';
    try {
      const knownHosts = await this.openKnownHosts();
      const saved = await knownHosts.get(this.knownHostId(host, port), '');
      if (this.generation !== generation) {
        return;
      }
      if (typeof saved === 'string' && saved) {
        options.fingerprint = saved;
        this.beginConnection(request);
        return;
      }
      // 首次握手只取指纹，确认前不向主机发送用户名或凭据。
      const peer = await this.openPeer(request, generation);
      let observed: string;
      try {
        if (this.generation !== generation) return;
        observed = await probeHostKey({ host, port, peer });
      } finally {
        if (peer) releasePeer(peer);
      }
      if (this.generation === generation) {
        this.pendingTrustConnection = request;
        this.hostKeyReview = { host, port, observed, previous: '', reconnect: true };
      }
    } catch (error) {
      if (this.generation === generation) {
        this.errorText = (error as Error).message || '无法核对 SSH 主机密钥。';
      }
    } finally {
      if (this.generation === generation) {
        this.checkingHostKey = false;
      }
    }
  }

  private cancelHostKeyReview(): void {
    if (!this.checkingHostKey) {
      this.pendingTrustConnection = undefined;
      this.hostKeyReview = undefined;
      this.errorText = '';
    }
  }

  private async confirmHostKey(): Promise<void> {
    const review = this.hostKeyReview;
    if (!review || this.checkingHostKey) {
      return;
    }
    const generation = this.generation;
    this.checkingHostKey = true;
    this.errorText = '';
    try {
      const knownHosts = await this.openKnownHosts();
      if (this.generation !== generation) {
        return;
      }
      const id = this.knownHostId(review.host, review.port);
      await knownHosts.put(id, review.observed);
      try {
        await knownHosts.flush();
      } catch (_) {
        // 写入失败时恢复内存中的旧记录，避免把未持久化的指纹当作已保存。
        knownHosts.putSync(id, review.previous);
        throw new Error('无法保存主机密钥。');
      }
      if (this.generation !== generation) {
        return;
      }
      const request = this.pendingTrustConnection;
      this.pendingTrustConnection = undefined;
      this.hostKeyReview = undefined;
      if (request) {
        request.options.fingerprint = review.observed;
        this.beginConnection(request);
      }
    } catch (_) {
      if (this.generation === generation) {
        this.errorText = '无法保存主机密钥，请重试。';
      }
    } finally {
      if (this.generation === generation) {
        this.checkingHostKey = false;
      }
    }
  }

  private beginConnection(request: SshOpenRequest): void {
    this.checkingHostKey = false;
    this.pendingConnection = request;
    this.receivedTerminalOutput = false;
    this.moshActive = request.options.useMosh === true;
    this.openedPushLink = request.options.pushLink;
    if (this.openedPushLink) this.pickingNotificationHost = false;
    this.openedRemoteTitle = request.options.zellijSession || (request.options.pushLink ? '通知会话' : 'Shell');
    this.openedHostLabel = request.server ? this.hostLabel(request.server) :
      (this.serverAlias.trim() || (request.pairing ? 'P2P 主机' : request.options.host));
    this.terminalServerId = request.server?.id ?? 0;
    this.recentServerId = request.options.pushLink ? 0 : this.terminalServerId;
    this.terminalEnded = false;
    this.terminalKeysVisible = false;
    this.clearCredentials();
    this.errorText = '';
    const generation = ++this.generation;
    this.statusText = '正在打开终端';
    this.view = new webview.WebviewController();
    this.bridge = this.createBridge(generation);
    // 同一帧内切换服务器时也重建 Web 终端，使控制器和原生桥接与新连接一致。
    this.terminalInstance = generation;
    // 键盘弹出时调整整个终端视图，快捷键栏留在键盘上方。
    const context = this.getUIContext();
    this.formKeyboardMode = context.getKeyboardAvoidMode();
    context.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.terminalVisible = true;
    this.loadTimer = setTimeout(() => {
      if (this.generation === generation && this.pendingConnection) {
        this.failOpening('终端启动超时，请重试。');
      }
    }, 8000);
  }

  private createBridge(generation: number): TerminalBridge {
    const current = (): boolean => this.generation === generation;
    return new TerminalBridge(
      (text: string) => { if (current()) this.queueText(text); },
      (encoded: string) => { if (current()) this.queueBinary(encoded); },
      (columns: number, rows: number) => { if (current()) this.onTerminalSize(columns, rows); },
      () => { if (current()) this.renderPending = false; },
      {
        wasm: (offset: number): string => current() ? this.moshWasmChunk(offset) : '',
        key: (): string => current() ? this.takeMoshKey() : '',
        datagram: (encoded: string) => { if (current()) this.writeMoshPacket(encoded); },
        rebind: () => {
          if (current() && this.moshActive && this.connection) {
            if (this.p2pSession) this.rebindP2p(this.p2pSession, this.connection, generation);
            else rebindMosh(this.connection);
          }
        },
        state: (status: string) => { if (current()) this.onMoshState(status); }
      }
    );
  }

  private onTerminalSize(columns: number, rows: number): void {
    if (!this.terminalVisible || !Number.isInteger(columns) || !Number.isInteger(rows) || columns < 2 || rows < 2) {
      return;
    }
    this.latestSize = { columns: Math.min(columns, 500), rows: Math.min(rows, 500) };
    const request = this.pendingConnection;
    if (request) {
      this.pendingConnection = undefined;
      clearTimeout(this.loadTimer);
      this.loadTimer = -1;
      request.options.columns = this.latestSize.columns;
      request.options.rows = this.latestSize.rows;
      this.sentSize = this.latestSize;
      this.openConnection(request, this.generation);
    }
  }

  private async openConnection(request: SshOpenRequest, generation: number): Promise<void> {
    const options = request.options;
    let peer: PeerHandle | undefined;
    try {
      if (request.pairing) {
        this.statusText = '正在协商 P2P 直连';
        peer = await this.openPeer(request, generation);
        if (this.generation !== generation) return;
      }
      this.statusText = options.useMosh ? '正在通过 SSH 启动 Mosh' : '正在连接 SSH';
      if (request.server) {
        const credentials = await this.savedServerStore().credentials(request.server);
        if (this.generation !== generation) {
          return;
        }
        options.password = credentials.password;
        options.privateKey = credentials.privateKey;
        options.passphrase = credentials.passphrase;
      }
      let opening: Promise<SshHandle>;
      try {
        options.peer = peer;
        opening = connect(options);
      } finally {
        // 原生模块同步复制参数，后台握手和换钥确认期间不再持有 ArkTS 凭据副本。
        options.password = '';
        options.privateKey = '';
        options.passphrase = '';
        options.peer = undefined;
      }
      const connection = await opening;
      if (this.generation !== generation) {
        disconnect(connection);
        return;
      }
      this.connection = connection;
      this.p2pSession = request.pairing;
      if (this.moshActive) {
        this.statusText = '正在连接 Mosh';
        this.runTerminalScript('window.nerveTerminal.startMosh(' + options.columns + ',' + options.rows + ')');
      } else {
        this.connected = true;
        this.statusText = request.pairing ? 'SSH 已连接 · P2P 直连' : 'SSH 已连接';
        this.rememberRecentConnection();
      }
      this.ioTimer = setInterval(() => this.pumpTerminal(), POLL_MS);
      if (request.server && options.discoverDaemon) {
        this.rememberDaemonHost(request.server, connection);
      }
    } catch (error) {
      if (this.generation === generation) {
        const failure = error as SshError;
        if (failure.fingerprint) {
          // 原生层已在用户认证前断开，须明确确认新密钥才能再次登录。
          this.backToForm();
          this.pendingTrustConnection = request.server ? request : undefined;
          // 用户信任新指纹后再次读取 Daemon 身份。
          options.discoverDaemon = request.server !== undefined;
          this.hostKeyReview = {
            host: options.host, port: options.port, observed: failure.fingerprint, previous: options.fingerprint,
            reconnect: request.server !== undefined
          };
        } else {
          this.failOpening(failure.message || (options.useMosh ? 'Mosh 连接失败。' : 'SSH 连接失败。'));
        }
      }
    } finally {
      if (peer) releasePeer(peer);
    }
  }

  private async rebindP2p(pairing: P2pPairing, connection: SshHandle, generation: number): Promise<void> {
    if (this.reconnectingP2p || this.closingMosh) return;
    this.reconnectingP2p = true;
    let peer: PeerHandle | undefined;
    const current = (): boolean => this.generation === generation && !this.closingMosh;
    try {
      // 只重新打洞并绑定原来的 UDP 端口。原生 Mosh 会话和 Web 终端引擎继续保留。
      peer = await dialP2p(pairing, current);
      if (current()) resumeP2pMosh(connection, peer);
    } catch (_) {
      if (current()) this.statusText = 'P2P 等待网络恢复';
    } finally {
      if (peer) releasePeer(peer);
      if (this.generation === generation) this.reconnectingP2p = false;
    }
  }

  private async rememberDaemonHost(server: SavedSshServer, connection: SshHandle): Promise<void> {
    this.managingServers = true;
    try {
      const daemonHostId = hostIdFromDaemonHealth(daemonHealth(connection));
      if (!daemonHostId || daemonHostId === server.daemonHostId) {
        return;
      }
      if (await this.savedServerStore().bindDaemonHost(server, daemonHostId)) {
        const updated: SavedSshServer = {
          id: server.id, alias: server.alias, host: server.host, port: server.port, username: server.username,
          zellijSession: server.zellijSession, usePrivateKey: server.usePrivateKey, daemonHostId,
          useMosh: server.useMosh, moshPort: server.moshPort, p2pEndpoint: server.p2pEndpoint
        };
        this.savedServers = this.savedServers.map((item: SavedSshServer): SavedSshServer =>
          item.id === updated.id ? updated : item);
      }
    } catch (_) {
      // 本地存储暂不可写时保留已打开的终端，后续连接可重新确认绑定。
    } finally {
      this.managingServers = false;
    }
  }

  private failOpening(message: string): void {
    this.backToForm();
    this.errorText = message;
  }

  private moshWasmChunk(offset: number): string {
    if (!this.moshActive || !this.connection || !Number.isInteger(offset) || offset < 0 ||
      offset % MOSH_WASM_CHUNK !== 0) {
      return '';
    }
    if (offset === 0) {
      // 桥接只提供一个固定资源，不向终端页面开放文件或网络访问。
      this.moshWasm = this.getUIContext().getHostContext()?.resourceManager
        .getRawFileContentSync('terminal/vendor/nerve-mosh.wasm');
    }
    const wasm = this.moshWasm;
    if (!wasm || offset >= wasm.length) {
      this.moshWasm = undefined;
      return '';
    }
    return this.base64.encodeToStringSync(wasm.subarray(offset, offset + MOSH_WASM_CHUNK));
  }

  private takeMoshKey(): string {
    if (!this.moshActive || !this.connection) {
      return '';
    }
    const info = takeMoshInfo(this.connection);
    this.moshPort = info.port;
    return info.key;
  }

  private writeMoshPacket(encoded: string): void {
    if (this.moshActive && this.connection && encoded.length <= MOSH_MAX_ENCODED_PACKET) {
      const packet = this.base64.decodeSync(encoded);
      sendMoshDatagram(this.connection, packet.buffer);
    }
  }

  private onMoshState(status: string): void {
    if (!this.moshActive) {
      return;
    }
    if (this.closingMosh) {
      if (status === 'closed' || status === 'error') this.finishMoshClose();
      return;
    }
    if (status === 'online') {
      this.connected = true;
      this.statusText = this.p2pSession ? 'Mosh 已连接 · P2P 直连' : 'Mosh 已连接';
      this.rememberRecentConnection();
    } else if (status === 'waiting') {
      const port = this.p2pSession ? ' · P2P' : ' · UDP ' + this.moshPort;
      this.statusText = this.connected ? 'Mosh 等待网络恢复' + port : '等待 Mosh 响应' + port;
    } else if (status === 'ended') {
      this.stopConnection();
      this.terminalEnded = true;
      this.statusText = '远端 Mosh 会话已结束';
    } else if (status === 'error') {
      this.onTerminalError();
    }
  }

  // 主动离开或打开另一条通知时，先完成 Mosh 关闭握手，释放开发机的 UDP 端口。
  private closeTerminal(afterClose: () => void): void {
    if (this.closingMosh) {
      return;
    }
    if (!this.moshActive || !this.connection || !this.moshPort) {
      afterClose();
      return;
    }
    this.closingMosh = true;
    this.connected = false;
    this.statusText = '正在断开 Mosh';
    this.afterMoshClose = afterClose;
    this.moshCloseTimer = setTimeout(() => this.finishMoshClose(), MOSH_CLOSE_MS);
    this.runTerminalScript('window.nerveTerminal.closeMosh()');
  }

  private finishMoshClose(): void {
    const afterClose = this.afterMoshClose;
    this.afterMoshClose = undefined;
    if (afterClose) afterClose();
  }

  private backToForm(): void {
    this.terminalMenuVisible = false;
    this.stopConnection();
    this.terminalVisible = false;
    this.terminalKeysVisible = false;
    this.getUIContext().setKeyboardAvoidMode(this.formKeyboardMode);
    this.errorText = '';
  }

  private stopConnection(): void {
    this.generation++;
    clearTimeout(this.loadTimer);
    clearInterval(this.ioTimer);
    clearTimeout(this.moshCloseTimer);
    this.loadTimer = -1;
    this.ioTimer = -1;
    this.moshCloseTimer = -1;
    this.afterMoshClose = undefined;
    this.moshActive = false;
    this.p2pSession = undefined;
    this.reconnectingP2p = false;
    this.moshPort = 0;
    this.moshWasm = undefined;
    this.moshPumpPending = false;
    this.closingMosh = false;
    this.pendingConnection = undefined;
    this.recentServerId = 0;
    const connection = this.connection;
    this.connection = undefined;
    if (connection) {
      disconnect(connection);
    }
    this.connected = false;
    this.ctrlArmed = false;
    this.inputQueue = [];
    this.queuedBytes = 0;
    this.inputOffset = 0;
    this.writePending = false;
    this.renderPending = false;
    this.resizePending = undefined;
  }

  private queueText(text: string): void {
    if (!this.connected || !text) {
      return;
    }
    if (this.ctrlArmed && text.length === 1) {
      const ch = text.toUpperCase().charCodeAt(0);
      if (ch >= 64 && ch <= 95) {
        text = String.fromCharCode(ch & 31);
      }
      this.ctrlArmed = false;
    }
    if (text.length > MAX_QUEUED_BYTES) {
      this.errorText = '输入太长，请分段发送。';
      return;
    }
    this.queueBytes(this.encoder.encodeInto(text));
  }

  private queueBinary(encoded: string): void {
    if (this.connected && encoded.length <= 4 * MAX_CHUNK_BYTES) {
      this.queueBytes(this.base64.decodeSync(encoded));
    }
  }

  private queueBytes(bytes: Uint8Array): void {
    if (this.queuedBytes + bytes.length > MAX_QUEUED_BYTES) {
      this.errorText = '终端输入队列已满，请稍后分段发送。';
      return;
    }
    this.errorText = '';
    for (let offset = 0; offset < bytes.length; offset += MAX_CHUNK_BYTES) {
      const length = Math.min(MAX_CHUNK_BYTES, bytes.length - offset);
      const chunk = new ArrayBuffer(length);
      new Uint8Array(chunk).set(bytes.subarray(offset, offset + length));
      this.inputQueue.push(chunk);
    }
    this.queuedBytes += bytes.length;
  }

  private sendInput(connection: SshHandle): boolean {
    if (this.inputQueue.length === 0) {
      return true;
    }
    const chunk = this.inputQueue[0];
    const sent = write(connection, chunk, this.inputOffset);
    this.writePending = sent === 0;
    this.inputOffset += sent;
    this.queuedBytes -= sent;
    if (this.inputOffset === chunk.byteLength) {
      this.inputQueue.shift();
      this.inputOffset = 0;
    }
    return !this.writePending;
  }

  private async pumpMosh(connection: SshHandle, generation: number): Promise<void> {
    if (this.moshPumpPending) {
      return;
    }
    this.moshPumpPending = true;
    try {
      // UDP 保留数据报边界，每帧限制桥接和解包的开销。
      const datagrams: string[] = [];
      for (let i = 0; i < MOSH_READ_BATCH; i++) {
        const packet = read(connection);
        if (!packet || packet.byteLength === 0) {
          break;
        }
        datagrams.push(this.base64.encodeToStringSync(new Uint8Array(packet)));
      }
      const chunk = this.closingMosh ? undefined : this.inputQueue[0];
      const currentSize = this.latestSize;
      const changed = !this.closingMosh &&
        (currentSize.columns !== this.sentSize.columns || currentSize.rows !== this.sentSize.rows);
      if (!datagrams.length && !chunk && !changed) {
        return;
      }
      const input = chunk ? this.base64.encodeToStringSync(new Uint8Array(chunk)) : '';
      const result = await this.view.runJavaScript('window.nerveTerminal.pumpMosh(' + JSON.stringify(datagrams) + ',' +
        JSON.stringify(input) + ',' + (changed ? currentSize.columns : 0) + ',' + (changed ? currentSize.rows : 0) + ')');
      if (this.generation === generation && result === 'true') {
        if (changed) this.sentSize = currentSize;
        if (chunk) {
          this.inputQueue.shift();
          this.queuedBytes -= chunk.byteLength;
        }
      }
    } catch (_) {
      if (this.generation === generation) this.onTerminalError();
    } finally {
      if (this.generation === generation) this.moshPumpPending = false;
    }
  }

  private pumpTerminal(): void {
    const connection = this.connection;
    if (!connection) {
      return;
    }
    if (this.moshActive) {
      this.pumpMosh(connection, this.generation);
      return;
    }
    try {
      // libssh2 需以相同的参数重试未完成的写入或窗口尺寸请求。
      if (this.writePending && !this.sendInput(connection)) {
        return;
      }
      if (this.latestSize.columns !== this.sentSize.columns || this.latestSize.rows !== this.sentSize.rows) {
        this.resizePending = this.resizePending ?? this.latestSize;
      }
      const size = this.resizePending;
      if (size) {
        if (!resize(connection, size.columns, size.rows)) {
          return;
        }
        this.sentSize = size;
        this.resizePending = undefined;
      }
      if (!this.sendInput(connection) || this.renderPending) {
        return;
      }
      const bytes = read(connection);
      if (bytes === undefined) {
        return;
      }
      if (bytes.byteLength === 0) {
        const sessionClosed = this.openedPushLink && exitStatus(connection) === SESSION_UNAVAILABLE_EXIT_STATUS;
        if (this.openedPushLink && !sessionClosed && !this.receivedTerminalOutput) {
          this.errorText = '未能打开通知对应的会话，请确认会话仍在运行。';
        }
        this.stopConnection();
        this.terminalEnded = true;
        this.statusText = sessionClosed ? 'Zellij 会话已关闭或改名' : '远端已断开';
        return;
      }
      this.receivedTerminalOutput = true;
      this.renderPending = true;
      const encoded = this.base64.encodeToStringSync(new Uint8Array(bytes));
      this.runTerminalScript('window.nerveTerminal.write(' + JSON.stringify(encoded) + ')');
    } catch (error) {
      this.stopConnection();
      this.terminalEnded = true;
      this.statusText = 'SSH 已断开';
      this.errorText = (error as Error).message || '终端连接中断。';
    }
  }

  private runTerminalScript(script: string): void {
    const generation = this.generation;
    this.view.runJavaScript(script).catch(() => {
      if (this.generation === generation && this.terminalVisible) {
        this.onTerminalError();
      }
    });
  }

  private onTerminalError(): void {
    if (this.closingMosh) {
      this.finishMoshClose();
      return;
    }
    const mosh = this.moshActive;
    if (this.connected) {
      this.stopConnection();
      this.terminalEnded = true;
      this.statusText = mosh ? 'Mosh 已断开' : 'SSH 已断开';
      this.errorText = '终端显示中断，请重新连接。';
    } else if (this.terminalVisible) {
      this.failOpening(mosh ? '无法启动内置 Mosh 客户端，请重试。' : '无法加载内置终端，请重试。');
    }
  }

  private hostLabel(server: SavedSshServer): string {
    return server.alias || (server.p2pEndpoint ? 'P2P 主机' : this.knownHostId(server.host, server.port));
  }

  private serverById(id: number): SavedSshServer {
    // 首页只为当前仍存在的主机构建最近会话。
    return this.savedServers.find((item: SavedSshServer): boolean => item.id === id)!;
  }

  private availableRecents(): RecentSession[] {
    return this.recentSessions.filter((recent: RecentSession): boolean =>
      this.savedServers.some((server: SavedSshServer): boolean => recent.serverId === server.id));
  }

  private relativeTime(openedAt: number): string {
    const minutes = Math.max(0, Math.floor((Date.now() - openedAt) / 60000));
    if (minutes < 1) return '刚刚';
    if (minutes < 60) return minutes + ' 分钟前';
    if (minutes < 1440) return Math.floor(minutes / 60) + ' 小时前';
    return Math.floor(minutes / 1440) + ' 天前';
  }

  private addHost(): void {
    this.activeTab = 1;
    this.setServerEditor(true);
  }

  private onKeyboardHeightChanged(): void {
    if (this.terminalVisible) this.terminalKeysVisible = this.keyboardHeight > 0;
  }

  private toggleTerminalKeyboard(): void {
    this.terminalKeysVisible = !this.terminalKeysVisible;
    if (this.terminalKeysVisible) {
      try {
        this.getUIContext().getFocusController().requestFocus('nerve-terminal');
      } catch (_) {
        // 软键盘焦点仍由内置终端尝试获取。
      }
      this.runTerminalScript('window.nerveTerminal.focus()');
    } else {
      this.ctrlArmed = false;
      this.runTerminalScript('window.nerveTerminal.blur()');
    }
  }

  private reconnectTerminal(): void {
    const server = this.savedServers.find((item: SavedSshServer): boolean => item.id === this.terminalServerId);
    if (!server || !this.terminalEnded || this.managingServers) return;
    const link = this.openedPushLink;
    this.backToForm();
    this.startConnection(server, link);
  }

  @Builder
  iconButton(mark: Resource | string, label: string, onClick: () => void, terminal: boolean = false) {
    Button({ type: ButtonType.Normal }) {
      if (typeof mark === 'string') {
        Text(mark).fontSize(23).fontColor(terminal ? TERMINAL_TEXT : this.colors.foreground)
      } else {
        SymbolGlyph(mark).fontSize(20).fontColor([terminal ? TERMINAL_TEXT : this.colors.foreground])
      }
    }
    .width(44).height(44).borderRadius(13).backgroundColor(Color.Transparent)
    .accessibilityText(label).focusOnTouch(!terminal).onClick(onClick)
  }

  @Builder
  field(label: string, value: string, placeholder: string, inputType: InputType, max: number,
    change: (value: string) => void) {
    Column({ space: 5 }) {
      Text(label).fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.colors.muted)
      TextInput({ text: value, placeholder: placeholder })
        .type(inputType).maxLength(max).height(46).fontSize(16)
        .fontColor(this.colors.foreground).placeholderColor(this.colors.muted)
        .backgroundColor(this.colors.surface).border({ width: 1, color: this.colors.line }).borderRadius(12)
        .onChange(change)
    }.alignItems(HorizontalAlign.Start).width('100%')
  }

  @Builder
  optionButton($$: NerveOptionButtonParams) {
    Button($$.label, { type: ButtonType.Normal })
      .layoutWeight(1).height(44).borderRadius(10).fontSize(14).fontWeight(FontWeight.Medium)
      .fontColor($$.selected ? this.colors.accent : this.colors.muted)
      .backgroundColor($$.selected ? this.colors.surface : Color.Transparent)
      .accessibilitySelected($$.selected).onClick($$.onSelect)
  }

  @Builder
  actionButton(label: string, onClick: () => void, primary: boolean = true) {
    Button(label, { type: ButtonType.Normal })
      .layoutWeight(1).height(46).borderRadius(12).fontSize(14).fontWeight(FontWeight.Medium)
      .fontColor(primary ? Color.White : this.colors.foreground)
      .backgroundColor(primary ? this.colors.palette.action : this.colors.surface)
      .border({ width: primary ? 0 : 1, color: this.colors.line }).onClick(onClick)
  }

  @Builder
  sectionLabel(text: string) {
    Text(text).fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.colors.foreground)
      .width('100%').margin({ top: 8 })
  }

  @Builder
  tile(mark: Resource | string, warning: boolean = false) {
    Stack() {
      if (typeof mark === 'string') {
        Text(mark).fontFamily(APP_FONT).fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(warning ? this.colors.warning : this.colors.accent)
      } else {
        SymbolGlyph(mark).fontSize(19).fontColor([warning ? this.colors.warning : this.colors.accent])
      }
    }.width(36).height(36).borderRadius(11).backgroundColor(warning ? this.colors.warningSurface : this.colors.tint)
    .accessibilityLevel('no')
  }

  @Builder
  connectionError() {
    if (this.errorText) {
      Text(this.errorText).fontColor(this.colors.error).fontSize(14).width('100%')
        .padding(12).borderRadius(12).backgroundColor(this.colors.surface).copyOption(CopyOptions.LocalDevice)
    }
  }

  @Builder
  appBar() {
    Row({ space: 8 }) {
      Text('>_').fontFamily(APP_FONT).fontSize(15).fontWeight(FontWeight.Bold).fontColor(Color.White)
        .textAlign(TextAlign.Center).width(30).height(30).borderRadius(10)
        .linearGradient({ angle: 135, colors: [[this.colors.palette.ink, 0], [this.colors.palette.action, 1]] })
      Text('Nerve').fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.colors.foreground).layoutWeight(1)
      this.iconButton($r('sys.symbol.bell'), this.pushLink ? '通知，有关联会话' : '通知',
        () => this.showUtility('notifications'))
      this.iconButton($r('sys.symbol.gearshape'), '设置', () => this.showUtility('settings'))
    }.width('100%').constraintSize({ maxWidth: 540 }).padding({ left: 20, right: 12 })
  }

  @Builder
  continuationCard(server: SavedSshServer, openedAt: number) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Text('>_').fontFamily(APP_FONT).fontSize(30).fontColor('#dbffffff').textAlign(TextAlign.Center)
        .width(87).height(72).borderRadius(18).border({ width: 1, color: '#65ffffff' })
        .backgroundColor('#1affffff').rotate({ angle: -18 }).margin({ top: 24, right: 17 }).accessibilityLevel('no')
      Column({ space: 6 }) {
        Text('上次连接 · ' + this.relativeTime(openedAt)).fontSize(12).fontColor('#eef0ff')
        Text(server.zellijSession || 'Shell').fontFamily(APP_FONT).fontSize(28).fontWeight(FontWeight.Bold)
          .fontColor(Color.White).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.hostLabel(server) + (server.useMosh ? ' · Mosh' : ' · SSH')).fontSize(13).fontColor('#f4f3ff')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Button('继续会话  →', { type: ButtonType.Normal }).fontSize(14).fontWeight(FontWeight.Bold).height(44)
          .fontColor(this.colors.palette.deep).backgroundColor(Color.White).borderRadius(12).margin({ top: 8 })
          .onClick(() => this.useSavedServer(server.id, false))
      }.width('100%').alignItems(HorizontalAlign.Start).padding(18)
    }.width('100%').constraintSize({ minHeight: 172 }).borderRadius(23).clip(true)
    .linearGradient({ angle: 128, colors: [[this.colors.palette.deep, 0], [this.colors.palette.action, 0.72],
      [this.colors.palette.ink, 1]] })
  }

  @Builder
  recentRow(server: SavedSshServer, openedAt: number) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 9 }) {
        this.tile('>_')
        Column({ space: 4 }) {
          Text(server.zellijSession || 'Shell').fontFamily(APP_FONT).fontSize(15).fontWeight(FontWeight.Bold)
            .fontColor(this.colors.foreground).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.hostLabel(server) + (server.useMosh ? ' · Mosh' : ' · SSH')).fontSize(12).fontColor(this.colors.muted)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text(this.relativeTime(openedAt)).fontSize(12).fontColor(this.colors.muted)
        Text('›').fontSize(21).fontColor(this.colors.muted)
      }.width('100%').padding({ left: 10, right: 11, top: 7, bottom: 7 }).constraintSize({ minHeight: 58 })
    }.width('100%').backgroundColor(Color.Transparent).borderRadius(0).padding(0)
    .onClick(() => this.useSavedServer(server.id, false))
  }

  @Builder
  emptySessions() {
    Column({ space: 9 }) {
      this.tile('>_')
      Text('暂无最近会话').fontSize(17).fontWeight(FontWeight.Bold).fontColor(this.colors.foreground)
      Text(this.savedServers.length ? '连接一台主机后，可以在这里继续会话。' : '添加开发机，连接已有 Zellij 会话或 Shell。')
        .fontSize(13).fontColor(this.colors.muted).textAlign(TextAlign.Center)
      Button(this.savedServers.length ? '查看主机' : '添加主机', { type: ButtonType.Normal })
        .height(44).borderRadius(12).fontSize(14).fontColor(Color.White).backgroundColor(this.colors.palette.action)
        .margin({ top: 3 }).onClick(() => {
          if (this.savedServers.length) this.changeTab(1);
          else this.addHost();
        })
    }.width('100%').padding(22).backgroundColor(this.colors.surface)
    .border({ width: 1, color: this.colors.line }).borderRadius(19)
  }

  @Builder
  notificationEntry() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 9 }) {
        this.tile($r('sys.symbol.bell'), true)
        Column({ space: 3 }) {
          Text('会话通知').fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.colors.foreground)
          Text(this.notificationServer ? this.hostLabel(this.notificationServer) : '选择发送通知的主机')
            .fontSize(12).fontColor(this.colors.muted).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text('›').fontSize(21).fontColor(this.colors.muted)
      }.padding(10).width('100%').constraintSize({ minHeight: 58 })
    }.padding(0).width('100%').borderRadius(16).backgroundColor(this.colors.surface)
    .border({ width: 1, color: this.colors.line }).onClick(() => this.showUtility('notifications'))
  }

  @Builder
  storeStatus() {
    if (this.serverListUnavailable) {
      Row({ space: 12 }) {
        Text('暂时无法读取已保存的主机').fontSize(14).fontColor(this.colors.error).layoutWeight(1)
        Button('重试').height(44).backgroundColor(this.colors.tint).fontColor(this.colors.accent)
          .enabled(!this.managingServers).onClick(() => this.loadSavedServers())
      }.width('100%')
    } else if (this.managingServers && !this.savedServers.length) {
      Text('正在读取主机…').fontSize(14).fontColor(this.colors.muted)
    }
  }

  @Builder
  sessionHome() {
    Text('会话').fontSize(34).fontWeight(FontWeight.Bold).fontColor(this.colors.foreground)
      .width('100%').margin({ bottom: 3 })
    this.storeStatus()
    if (this.availableRecents().length) {
      ForEach(this.availableRecents().slice(0, 1), (item: RecentSession) => {
        this.continuationCard(this.serverById(item.serverId), item.openedAt)
      }, (item: RecentSession): string => item.serverId + ':' + item.openedAt)
    } else if (!this.managingServers && !this.serverListUnavailable) {
      this.emptySessions()
    }
    if (this.pushLink) this.notificationEntry()
    if (this.availableRecents().length > 1) {
      this.sectionLabel('最近会话')
      Column() {
        ForEach(this.availableRecents().slice(1), (item: RecentSession, index: number) => {
          if (index > 0) Divider().color(this.colors.line).margin({ left: 53 })
          this.recentRow(this.serverById(item.serverId), item.openedAt)
        }, (item: RecentSession): string => item.serverId + ':' + item.openedAt)
      }.width('100%').borderRadius(17).clip(true).backgroundColor(this.colors.surface)
      .border({ width: 1, color: this.colors.line })
    }
  }

  @Builder
  savedServerRow(server: SavedSshServer) {
    Row() {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 9 }) {
          this.tile($r('sys.symbol.computer'))
          Column({ space: 4 }) {
            Text(this.hostLabel(server)).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.colors.foreground)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            // 固定端口优先显示，主机地址过长时仍能核对 Mosh 端口。
            Text(server.useMosh && !server.p2pEndpoint && server.moshPort > 0 ?
              'Mosh · UDP ' + server.moshPort + ' · ' + this.knownHostId(server.host, server.port) :
              (server.p2pEndpoint ? 'P2P 直连' : this.knownHostId(server.host, server.port)) +
              (server.useMosh ? ' · Mosh' : ' · SSH'))
              .fontSize(12).fontColor(this.colors.muted).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%').padding({ left: 10, top: 8, bottom: 8 }).constraintSize({ minHeight: 58 })
      }.layoutWeight(1).padding(0).borderRadius(0).backgroundColor(Color.Transparent)
      .onClick(() => this.useSavedServer(server.id, false))
      if (!this.pickingNotificationHost) {
        this.iconButton('⋯', '编辑 ' + this.hostLabel(server), () => this.useSavedServer(server.id, true))
      }
    }.width('100%').padding({ right: 4 })
  }

  @Builder
  hostHome() {
    Row() {
      Text('主机').fontSize(34).fontWeight(FontWeight.Bold).fontColor(this.colors.foreground).layoutWeight(1)
      Button('＋ 添加主机', { type: ButtonType.Normal }).height(44).borderRadius(12).fontSize(14)
        .fontColor(Color.White).backgroundColor(this.colors.palette.action).onClick(() => this.addHost())
    }.width('100%').margin({ bottom: 3 })
    this.storeStatus()
    if (this.pickingNotificationHost) {
      Row({ space: 8 }) {
        Text('选择发送通知的主机').fontSize(14).fontColor(this.colors.warning).layoutWeight(1)
        Button('取消').height(44).fontColor(this.colors.warning).backgroundColor(Color.Transparent)
          .onClick(() => { this.pickingNotificationHost = false; })
      }.width('100%').padding({ left: 10, right: 6 }).backgroundColor(this.colors.warningSurface).borderRadius(13)
    } else if (this.pushLink) {
      this.notificationEntry()
    }
    if (this.savedServers.length) {
      this.sectionLabel('已保存的主机')
      Column() {
        ForEach(this.savedServers, (server: SavedSshServer, index: number) => {
          if (index > 0) Divider().color(this.colors.line).margin({ left: 53 })
          this.savedServerRow(server)
        }, (server: SavedSshServer): string =>
          server.id + ':' + server.alias + ':' + server.host + ':' + server.port + ':' + server.useMosh)
      }.width('100%').borderRadius(17).clip(true).backgroundColor(this.colors.surface)
      .border({ width: 1, color: this.colors.line })
    } else if (!this.managingServers && !this.serverListUnavailable) {
      Text('暂无已保存的主机').fontSize(14).fontColor(this.colors.muted).width('100%').padding(20)
        .textAlign(TextAlign.Center).backgroundColor(this.colors.surface).borderRadius(17)
    }
  }

  // 底部导航仅高亮图标和文字，完整按钮区域仍可点击。
  @Builder
  bottomTab(index: number, label: string, mark: Resource | string) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 1 }) {
        Stack() {
          if (typeof mark === 'string') {
            Text(mark).fontFamily(APP_FONT).fontSize(15)
              .fontColor(this.activeTab === index ? this.colors.accent : this.colors.muted)
          } else {
            SymbolGlyph(mark).fontSize(18).fontColor([this.activeTab === index ? this.colors.accent : this.colors.muted])
          }
        }.width(44).height(24)
        Text(label).fontSize(12).fontWeight(this.activeTab === index ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.activeTab === index ? this.colors.accent : this.colors.muted)
      }.height(49).justifyContent(FlexAlign.Center).width('100%')
    }.layoutWeight(1).padding(0).backgroundColor(Color.Transparent).borderRadius(12).accessibilityText(label)
    .accessibilitySelected(this.activeTab === index).onClick(() => this.changeTab(index))
  }

  @Builder
  home() {
    Column() {
      this.appBar()
      Scroll() {
        Column({ space: 11 }) {
          if (this.activeTab === 0) this.sessionHome()
          else this.hostHome()
          if (this.checkingHostKey) {
            Text('正在核对主机…').fontSize(14).fontColor(this.colors.muted)
          }
          this.connectionError()
        }.width('100%').constraintSize({ maxWidth: 540 }).padding({ left: 20, right: 20, top: 16, bottom: 20 })
        .alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).align(Alignment.Top).enabled(!this.checkingHostKey && !this.managingServers)
      Divider().color(this.colors.line)
      Row({ space: 8 }) {
        this.bottomTab(0, '会话', '>_')
        this.bottomTab(1, '主机', $r('sys.symbol.computer'))
      }.width('100%').constraintSize({ maxWidth: 540 }).padding({ left: 24, right: 24, top: 4, bottom: 4 })
    }.width('100%').height('100%')
  }

  @Builder
  serverFields() {
    Row({ space: 4 }) {
      this.optionButton({ label: '手动连接', selected: !this.pairedConnection,
        onSelect: () => this.usePairedConnection(false) })
      this.optionButton({ label: '配对连接', selected: this.pairedConnection,
        onSelect: () => this.usePairedConnection(true) })
    }.width('100%').padding(4).borderRadius(14).backgroundColor(this.colors.line)
    this.sectionLabel('连接')
    this.field('名称（可选）', this.serverAlias, '例如 我的 WSL', InputType.Normal, 128,
      (value: string) => { this.serverAlias = value; })
    if (this.pairedConnection) {
      this.field('P2P 配对地址', this.p2pCode, '粘贴 nerve pair 的输出', InputType.Password, 512,
        (value: string) => { this.p2pCode = value; })
    } else {
      Row({ space: 9 }) {
        Column() {
          this.field('主机地址', this.host, 'dev.example.local', InputType.Normal, 253,
            (value: string) => { this.host = value; })
        }.layoutWeight(2)
        Column() {
          this.field('端口', this.port, '22', InputType.Number, 5, (value: string) => { this.port = value; })
        }.layoutWeight(1)
      }.width('100%')
    }
    this.field('用户名', this.username, 'SSH 用户', InputType.Normal, 128,
      (value: string) => { this.username = value; })
    this.field('默认 Zellij 会话', this.zellijSession, '留空打开 Shell', InputType.Normal, 128,
      (value: string) => { this.zellijSession = value; })
    Text('传输协议').fontSize(13).fontColor(this.colors.muted)
    Row({ space: 4 }) {
      this.optionButton({ label: 'SSH', selected: !this.useMosh, onSelect: () => { this.useMosh = false; } })
      this.optionButton({ label: 'Mosh', selected: this.useMosh, onSelect: () => { this.useMosh = true; } })
    }.width('100%').padding(4).borderRadius(14).backgroundColor(this.colors.line)
    this.sectionLabel('身份验证')
    Row({ space: 4 }) {
      this.optionButton({ label: '密码', selected: !this.usePrivateKey, onSelect: () => this.changeAuth(false) })
      this.optionButton({ label: '私钥', selected: this.usePrivateKey, onSelect: () => this.changeAuth(true) })
    }.width('100%').padding(4).borderRadius(14).backgroundColor(this.colors.line)
    if (this.usePrivateKey) {
      Button(this.keySelected ? '已选私钥 · 更换' :
        this.canKeepSavedCredentials() ? '已保存私钥 · 更换' : '选择私钥文件', { type: ButtonType.Normal })
        .width('100%').height(44).borderRadius(12).fontSize(14)
        .fontColor(this.colors.accent).backgroundColor(this.colors.tint).onClick(() => this.selectKey())
      if (this.keySelected || !this.canKeepSavedCredentials()) {
        this.field('私钥口令', this.passphrase, '未加密时留空', InputType.Password, 1024,
          (value: string) => { this.passphrase = value; })
      }
    } else {
      this.field('SSH 密码', this.password, this.canKeepSavedCredentials() ? '留空保留已保存密码' : '输入密码',
        InputType.Password, 1024, (value: string) => { this.password = value; })
    }
    if (this.useMosh && !this.pairedConnection) {
      Button(this.advancedConnection ? '收起高级选项  −' : '高级选项  ＋', { type: ButtonType.Normal })
        .height(44).borderRadius(12).backgroundColor(this.colors.surface).fontColor(this.colors.foreground)
        .onClick(() => { this.advancedConnection = !this.advancedConnection; })
      if (this.advancedConnection) {
        this.field('Mosh UDP 端口', this.moshPortInput, '填写固定端口 · 留空自动分配', InputType.Number, 5,
          (value: string) => { this.moshPortInput = value; })
      }
    }
    this.connectionError()
    Row({ space: 8 }) {
      this.actionButton(this.editingServer ? '保存修改' : '保存主机', () => { this.saveServer(); }, !!this.editingServer)
      if (!this.editingServer) {
        this.actionButton(this.checkingHostKey ? '正在核对主机' : this.pickingNotificationHost ? '连接并打开会话' : '连接',
          () => this.startConnection(undefined, this.pickingNotificationHost ? this.pushLink : ''))
      }
    }.width('100%').margin({ top: 4 })
    if (this.editingServer) {
      Button('删除主机', { type: ButtonType.Normal }).width('100%').height(44)
        .fontSize(14).fontColor(this.colors.error).backgroundColor(Color.Transparent).onClick(() => this.removeServer())
    }
  }

  @Builder
  editor() {
    Column() {
      Row({ space: 4 }) {
        this.iconButton('‹', '返回', () => this.setServerEditor(false))
        Text(this.editingServer ? '编辑主机' : '添加主机').fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor(this.colors.foreground)
      }.width('100%').constraintSize({ maxWidth: 540 }).padding({ left: 8 })
      Scroll() {
        Column({ space: 10 }) {
          this.serverFields()
        }.width('100%').constraintSize({ maxWidth: 540 }).padding({ left: 20, right: 20, top: 8, bottom: 20 })
        .alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).align(Alignment.Top).enabled(!this.checkingHostKey && !this.managingServers)
    }.width('100%').height('100%')
  }

  @Builder
  paletteOption(palette: ThemePalette) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 8 }) {
        Stack().width(30).height(30).borderRadius(9)
          .linearGradient({ angle: 140, colors: [[palette.deep, 0], [palette.action, 0.62], [palette.glow, 1]] })
        Text(palette.name).fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.colors.foreground).layoutWeight(1)
        if (this.colors.palette.id === palette.id) {
          Text('✓').fontSize(15).fontColor(this.colors.accent)
        }
      }.width('100%').padding(8)
    }.layoutWeight(1).height(52).padding(0).borderRadius(12)
    .backgroundColor(this.colors.palette.id === palette.id ? this.colors.tint : this.colors.surface)
    .border({ width: 1, color: this.colors.palette.id === palette.id ? this.colors.accent : this.colors.line })
    .accessibilityText(palette.name).accessibilitySelected(this.colors.palette.id === palette.id)
    .onClick(() => this.changeAppearance(palette.id, this.darkAppearance))
  }

  @Builder
  appearanceSettings() {
    this.sectionLabel('外观')
    Row({ space: 4 }) {
      this.optionButton({ label: '浅色', selected: !this.darkAppearance,
        onSelect: () => this.changeAppearance(this.colors.palette.id, false) })
      this.optionButton({ label: '深色', selected: this.darkAppearance,
        onSelect: () => this.changeAppearance(this.colors.palette.id, true) })
    }.width('100%').padding(4).borderRadius(14).backgroundColor(this.colors.line)
    this.sectionLabel('主题色')
    Row({ space: 8 }) {
      this.paletteOption(PALETTES[0])
      this.paletteOption(PALETTES[1])
    }.width('100%')
    Row({ space: 8 }) {
      this.paletteOption(PALETTES[2])
      this.paletteOption(PALETTES[3])
    }.width('100%')
    if (this.preferenceError) {
      Text(this.preferenceError).fontSize(13).fontColor(this.colors.error).width('100%')
    }
    Button('推送通知设置  ›', { type: ButtonType.Normal }).width('100%').height(48).borderRadius(12)
      .fontSize(14).fontColor(this.colors.foreground).backgroundColor(this.colors.surface)
      .border({ width: 1, color: this.colors.line }).margin({ top: 4 }).onClick(() => {
        this.utilityVisible = false;
        this.pushSettingsVisible = true;
      })
  }

  @Builder
  notificationSettings() {
    if (this.pushLink) {
      Text(this.notificationServer ? this.hostLabel(this.notificationServer) : '请选择发送通知的主机。')
        .fontSize(14).fontColor(this.colors.muted)
      Row({ space: 8 }) {
        this.actionButton('清除通知', () => {
          AppStorage.set<string>('nervePushLink', '');
          this.utilityVisible = false;
        }, false)
        if (!this.terminalVisible || this.pushLink !== this.openedPushLink) {
          this.actionButton(this.notificationServer ? '打开会话' : '选择主机', () => {
            if (this.notificationServer) this.openMatchedNotification();
            else this.chooseNotificationHost();
          })
        }
      }.width('100%').enabled(!this.managingServers && !this.checkingHostKey && !this.closingMosh)
    } else {
      Text('暂无会话通知').fontSize(14).fontColor(this.colors.muted)
    }
  }

  @Builder
  utilitySheet() {
    Column({ space: 8 }) {
      Row() {
        Text(this.utilityPage === 'settings' ? '设置' : this.utilityPage === 'notifications' ? '通知' : '终端操作')
          .layoutWeight(1).fontSize(21).fontWeight(FontWeight.Bold).fontColor(this.colors.foreground)
        this.iconButton('×', '关闭', () => { this.utilityVisible = false; })
      }.width('100%')
      if (this.utilityPage === 'settings') {
        this.appearanceSettings()
      } else if (this.utilityPage === 'notifications') {
        this.notificationSettings()
      } else {
        Button(this.terminalEnded ? '返回' : '断开并返回', { type: ButtonType.Normal }).width('100%').height(44)
          .fontColor(this.colors.error).backgroundColor(this.colors.warningSurface).borderRadius(12)
          .enabled(!this.closingMosh).onClick(() => {
            this.utilityVisible = false;
            this.closeTerminal(() => this.backToForm());
          })
      }
    }.width('100%').padding({ left: 20, right: 20, top: 8, bottom: 20 }).alignItems(HorizontalAlign.Start)
    .backgroundColor(this.colors.surface)
  }

  @Builder
  hostKeyFingerprint(label: string, value: string) {
    Column({ space: 6 }) {
      Text(label).fontFamily(APP_FONT).fontSize(13).fontColor(this.colors.muted)
      Text(value).fontFamily(APP_FONT).fontSize(14).fontColor(this.colors.foreground)
        .wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12).borderRadius(10).backgroundColor(this.colors.surface)
  }

  @Builder
  reviewHostKey(review: HostKeyReview) {
    Scroll() {
      Column({ space: 14 }) {
        Text(review.previous ? 'SSH 主机密钥已变化' : '首次连接此主机')
          .fontFamily(APP_FONT).fontSize(24).fontWeight(FontWeight.Bold)
          .fontColor(review.previous ? this.colors.error : this.colors.foreground)
        Text(this.knownHostId(review.host, review.port)).fontFamily(APP_FONT).fontSize(15).fontColor(this.colors.foreground)
          .wordBreak(WordBreak.BREAK_ALL)
        Text(review.previous ?
          '连接已阻止。请在开发机或可信渠道核对新指纹。' + (review.reconnect ? '' : '更新信任后，需要重新填写 SSH 凭据。') :
          '请确认这是你的开发机。确认后，Nerve 会在此设备记住它的主机密钥。')
          .fontFamily(APP_FONT).fontSize(14).fontColor(this.colors.muted)
        if (review.previous) {
          this.hostKeyFingerprint('已保存的指纹', review.previous)
        }
        this.hostKeyFingerprint(review.previous ? '新指纹' : '主机指纹', review.observed)
        if (this.errorText) {
          Text(this.errorText).fontFamily(APP_FONT).fontSize(14).fontColor(this.colors.error)
        }
        Row({ space: 10 }) {
          Button('取消', { type: ButtonType.Normal })
            .layoutWeight(1).height(44).borderRadius(10).fontFamily(APP_FONT).fontSize(15)
            .fontColor(this.colors.foreground).backgroundColor(this.colors.surface)
            .onClick(() => this.cancelHostKeyReview())
          Button(review.previous ? review.reconnect ? '更新并连接' : '更新信任' : '信任并连接',
            { type: ButtonType.Normal })
            .layoutWeight(1).height(44).borderRadius(10).fontFamily(APP_FONT).fontSize(15)
            .fontColor(Color.White).backgroundColor(this.colors.palette.action)
            .onClick(() => this.confirmHostKey())
        }.width('100%').enabled(!this.checkingHostKey)
      }
      .width('100%')
      .constraintSize({ maxWidth: 540 })
      .padding({ left: 20, top: 24, right: 20, bottom: 28 })
      .alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').align(Alignment.Top)
  }

  @Builder
  formatKey(label: string, name: string, description: string) {
    Button(label, { type: ButtonType.Normal }).layoutWeight(1).padding(0).height(44).borderRadius(9)
      .fontFamily(APP_FONT).fontSize(14).fontColor(TERMINAL_TEXT).backgroundColor(TERMINAL_SURFACE)
      .accessibilityText(description).focusOnTouch(false).enabled(this.connected)
      .onClick(() => this.runTerminalScript('window.nerveTerminal.key(' + JSON.stringify(name) + ')'))
  }

  @Builder
  terminalToolbar() {
    Column() {
      Row() {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 7 }) {
            SymbolGlyph($r('sys.symbol.keyboard')).fontSize(19).fontColor([TERMINAL_TEXT])
            Text(this.terminalKeysVisible ? '收起键盘' : '打开键盘').fontSize(13).fontColor(TERMINAL_TEXT)
          }.padding({ left: 9, right: 9 })
        }.height(44).padding(0).borderRadius(10).backgroundColor(Color.Transparent).focusOnTouch(false)
        .enabled(this.connected).onClick(() => this.toggleTerminalKeyboard())
      }.width('100%').padding({ left: 4 })
      if (this.terminalKeysVisible) {
        Row({ space: 3 }) {
          Button('Ctrl', { type: ButtonType.Normal }).layoutWeight(1).padding(0).height(44).borderRadius(9)
            .fontFamily(APP_FONT).fontSize(13).fontColor(TERMINAL_TEXT)
            .backgroundColor(this.ctrlArmed ? this.colors.palette.action : TERMINAL_SURFACE)
            .accessibilitySelected(this.ctrlArmed).focusOnTouch(false).enabled(this.connected)
            .onClick(() => {
              this.ctrlArmed = !this.ctrlArmed;
              this.runTerminalScript('window.nerveTerminal.focus()');
            })
          this.formatKey('Esc', 'escape', 'Escape 键')
          this.formatKey('Tab', 'tab', 'Tab 键')
          this.formatKey('←', 'left', '左方向键')
          this.formatKey('↓', 'down', '下方向键')
          this.formatKey('↑', 'up', '上方向键')
          this.formatKey('→', 'right', '右方向键')
        }.width('100%').padding({ left: 6, right: 6, bottom: 7 })
      }
    }.width('100%').backgroundColor(TERMINAL_TOOLBAR_BACKGROUND)
  }

  @Builder
  terminalMenuButton(accent: string) {
    Button({ type: ButtonType.Normal }) {
      Text('⋯').fontSize(23).fontColor('#f1f1fc')
    }.width(44).height(44).padding(0).borderRadius(13).backgroundColor(Color.Transparent)
    .accessibilityText('终端操作').focusOnTouch(false)
    .onClick(() => { this.terminalMenuVisible = true; })
    .bindSheet($$this.terminalMenuVisible, this.terminalMenuContent(accent), {
      height: SheetSize.FIT_CONTENT, dragBar: true, showClose: false,
      backgroundColor: NERVE_TERMINAL_MENU_BACKGROUND
    })
  }

  // 面板直接读取当前会话状态，连接结束或 Mosh 关闭中均能同步更新。
  @Builder
  terminalMenuContent(accent: string) {
    NerveTerminalMenu({
      sessionTitle: this.openedRemoteTitle, statusText: this.statusText,
      connected: this.connected, closing: this.closingMosh, accent,
      onClose: () => { this.terminalMenuVisible = false; },
      onExit: () => {
        this.terminalMenuVisible = false;
        this.closeTerminal(() => this.backToForm());
      }
    })
  }

  @Builder
  terminalView(instance: number) {
    Column() {
      Row({ space: 4 }) {
        this.iconButton('‹', '返回', () => this.closeTerminal(() => this.backToForm()), true)
        Column({ space: 3 }) {
          Text(this.openedRemoteTitle).fontFamily(APP_FONT).fontSize(16).fontWeight(FontWeight.Bold)
            .fontColor(TERMINAL_TEXT).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.openedHostLabel + (this.terminalEnded ? '' : ' · ' + this.statusText)).fontSize(12)
            .fontColor(this.terminalEnded ? '#ffcb80' :
              this.statusText.includes('已连接') ? '#80deb3' : TERMINAL_MUTED)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.pushLink && this.pushLink !== this.openedPushLink) {
          this.iconButton($r('sys.symbol.bell'), '查看通知', () => this.showUtility('notifications'), true)
        }
        this.terminalMenuButton(this.colors.palette.light)
      }.width('100%').padding({ left: 4, right: 7, top: 3, bottom: 3 })
      Divider().color('#2d3145')
      if (this.terminalEnded || this.errorText) {
        Row({ space: 8 }) {
          Text(this.errorText || this.statusText).fontSize(13).fontColor('#ffcf91').layoutWeight(1)
            .copyOption(CopyOptions.LocalDevice)
          if (this.terminalEnded && this.terminalServerId > 0) {
            Button('重新连接', { type: ButtonType.Normal }).height(44).borderRadius(10).fontSize(13)
              .fontColor('#ffdaac').backgroundColor('#503722').enabled(!this.managingServers)
              .onClick(() => this.reconnectTerminal())
          }
        }.width('100%').padding({ left: 12, right: 10, top: 5, bottom: 5 }).backgroundColor('#302623')
      }
      Web({ src: $rawfile('terminal/index.html'), controller: this.view })
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(TERMINAL_BACKGROUND)
        .id('nerve-terminal')
        .focusable(true)
        .javaScriptAccess(true)
        .fileAccess(false)
        .domStorageAccess(false)
        .blockNetwork(true)
        .multiWindowAccess(false)
        .allowWindowOpenMethod(false)
        .javaScriptProxy({
          object: this.bridge,
          name: 'nerveHost',
          methodList: ['onSize', 'onInput', 'onBinary', 'onOutputFlushed',
            'onMoshWasm', 'onMoshKey', 'onMoshDatagram', 'onMoshRebind', 'onMoshState'],
          controller: this.view
        })
        .onLoadIntercept(event => {
          const url = event.data.getRequestUrl();
          return event.data.isMainFrame() && url !== TERMINAL_URL && url !== TERMINAL_LOADED_URL &&
            url !== TERMINAL_FILE_URL;
        })
        .onPageEnd(() => {
          if (this.generation === instance) {
            this.runTerminalScript('window.nerveTerminal.setCursor(' + JSON.stringify(this.colors.palette.light) +
              ');window.nerveTerminal.start()');
          }
        })
        .onRenderExited(() => {
          if (this.generation === instance) this.onTerminalError();
        })
      Divider().color('#2d3145')
      this.terminalToolbar()
    }.width('100%').height('100%').backgroundColor(TERMINAL_BACKGROUND)
  }

  build() {
    Column() {
      if (this.terminalVisible) {
        ForEach([this.terminalInstance], (instance: number) => {
          this.terminalView(instance)
        }, (instance: number): string => String(instance))
      } else if (this.hostKeyReview) {
        this.reviewHostKey(this.hostKeyReview)
      } else if (this.pushSettingsVisible) {
        PushSettings({ colors: this.colors, onClose: () => { this.pushSettingsVisible = false; } })
      } else if (this.serverEditorOpen) {
        this.editor()
      } else {
        this.home()
      }
    }
    .width('100%').height('100%')
    .backgroundColor(this.terminalVisible ? TERMINAL_BACKGROUND : this.colors.background)
    .bindSheet($$this.utilityVisible, this.utilitySheet(), { height: SheetSize.FIT_CONTENT,
      dragBar: true, showClose: false, backgroundColor: this.colors.surface })
  }
}
