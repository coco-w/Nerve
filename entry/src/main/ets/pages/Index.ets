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
import { ACCENT, APP_FONT, BACKGROUND, ERROR, FOREGROUND, MUTED, SURFACE } from '../ui/Theme';

// ArkWeb 拦截时使用资源 URL，加载后可能显示为 RAWFILE 格式。
const TERMINAL_URL = 'resource://rawfile/terminal/index.html';
const TERMINAL_LOADED_URL = 'resource:/RAWFILE/terminal/index.html';
const TERMINAL_FILE_URL = 'file:///data/storage/el1/bundle/entry/resources/rawfile/terminal/index.html';
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
  @State private pushSettingsVisible: boolean = false;
  @State private openedPushLink: string = '';
  @State private openedRemoteTitle: string = '';
  @State @Watch('updateNotificationMatch') private savedServers: SavedSshServer[] = [];
  @State private notificationServer: SavedSshServer | undefined = undefined;
  @State private editingServer: SavedSshServer | undefined = undefined;
  // 首页始终是主机列表，新增和编辑操作才打开表单。
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
  @State private terminalVisible: boolean = false;
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
    this.loadSavedServers();
  }

  onPageShow(): void {
    const context = this.getUIContext().getHostContext();
    if (!context) return;
    window.getLastWindow(context).then((mainWindow: window.Window): Promise<void> => {
      // 主窗口、状态栏和底部手势区使用同一套连接页配色。
      mainWindow.setWindowBackgroundColor(BACKGROUND);
      return mainWindow.setWindowSystemBarProperties({
        statusBarColor: BACKGROUND,
        navigationBarColor: BACKGROUND,
        statusBarContentColor: FOREGROUND,
        navigationBarContentColor: FOREGROUND
      });
    }).catch(() => {
      // 窗口切换期间可能暂时不可用，页面再次显示时会重试。
    });
  }

  onBackPress(): boolean {
    if (this.terminalMenuVisible) {
      this.terminalMenuVisible = false;
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
    return false;
  }

  private onPushLinkChanged(): void {
    if (this.pushLink) this.pushSettingsVisible = false;
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
    // 收到或点击系统通知只选中服务器，由用户点「打开会话」后才读取凭据。
    if (this.terminalVisible) {
      this.closeTerminal(() => {
        this.backToForm();
        this.startConnection(server, link);
      });
    } else {
      this.startConnection(server, link);
    }
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
      this.startConnection(server, this.notificationServer ? '' : this.pushLink);
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
    this.port = server ? String(server.port) : '22';
    this.username = server?.username ?? '';
    this.zellijSession = server?.zellijSession ?? '';
    this.useMosh = server?.useMosh ?? false;
    this.moshPortInput = server?.moshPort ? String(server.moshPort) : '';
    this.usePrivateKey = server?.usePrivateKey ?? false;
    this.serverEditorOpen = isOpen;
  }

  private formHost(): string {
    const pairing = parseP2pPairing(this.p2pCode);
    if (pairing) return pairing.hostId;
    const host = this.host.trim().replace(/^\[([^\]]+)\]$/, '$1');
    return host.includes(':') ? host : host.toLowerCase();
  }

  private formSettings(useSession: boolean): SshServerSettings | undefined {
    const pairing = parseP2pPairing(this.p2pCode);
    if (this.p2pCode.trim() && !pairing) {
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
    this.openedRemoteTitle = request.options.zellijSession || (request.options.pushLink ?
      this.knownHostId(request.options.host, request.options.port) : request.options.host);
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
    } else if (status === 'waiting') {
      const port = this.p2pSession ? ' · P2P' : ' · UDP ' + this.moshPort;
      this.statusText = this.connected ? 'Mosh 等待网络恢复' + port : '等待 Mosh 响应' + port;
    } else if (status === 'ended') {
      this.stopConnection();
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
        this.statusText = sessionClosed ? 'Zellij 会话已关闭或改名' : '远端已断开';
        return;
      }
      this.receivedTerminalOutput = true;
      this.renderPending = true;
      const encoded = this.base64.encodeToStringSync(new Uint8Array(bytes));
      this.runTerminalScript('window.nerveTerminal.write(' + JSON.stringify(encoded) + ')');
    } catch (error) {
      this.stopConnection();
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
      this.statusText = mosh ? 'Mosh 已断开' : 'SSH 已断开';
      this.errorText = '终端显示中断，请重新连接。';
    } else if (this.terminalVisible) {
      this.failOpening(mosh ? '无法启动内置 Mosh 客户端，请重试。' : '无法加载内置终端，请重试。');
    }
  }

  @Builder
  field(label: string, value: string, placeholder: string, inputType: InputType, max: number,
    change: (value: string) => void) {
    Column({ space: 6 }) {
      Text(label).fontFamily(APP_FONT).fontSize(13).fontColor(MUTED)
      TextInput({ text: value, placeholder: placeholder })
        .type(inputType)
        .maxLength(max)
        .height(44)
        .fontSize(15)
        .fontFamily(APP_FONT)
        .fontColor(FOREGROUND)
        .placeholderFont({ size: 15, family: APP_FONT })
        .placeholderColor(MUTED)
        .backgroundColor(SURFACE)
        .borderRadius(10)
        .onChange(change)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  optionButton($$: NerveOptionButtonParams) {
    // 按引用读取选中状态，切换时同步刷新按钮和输入项。
    Button($$.label, { type: ButtonType.Normal })
      .layoutWeight(1)
      .height(38)
      .borderRadius(8)
      .fontFamily(APP_FONT)
      .fontSize(14)
      .fontColor($$.selected ? BACKGROUND : FOREGROUND)
      .backgroundColor($$.selected ? ACCENT : SURFACE)
      .onClick($$.onSelect)
  }

  @Builder
  formatKey(label: string, name: string, description: string) {
    Button(label, { type: ButtonType.Normal })
      .layoutWeight(1)
      .padding(0)
      .height(38)
      .borderRadius(8)
      .fontFamily(APP_FONT)
      .fontSize(14)
      .fontColor(FOREGROUND)
      .backgroundColor(SURFACE)
      .accessibilityText(description)
      .focusOnTouch(false)
      .enabled(this.connected)
      .onClick(() => this.runTerminalScript('window.nerveTerminal.key(' + JSON.stringify(name) + ')'))
  }

  @Builder
  connectionError() {
    if (this.errorText) {
      Text(this.errorText).fontFamily(APP_FONT).fontColor(ERROR).fontSize(14)
        .width('100%').copyOption(CopyOptions.LocalDevice)
    }
  }

  @Builder
  savedServerRow(server: SavedSshServer) {
    Row({ space: 8 }) {
      Column({ space: 4 }) {
        Text(server.alias || this.knownHostId(server.host, server.port))
          .fontFamily(APP_FONT).fontSize(15).fontColor(FOREGROUND)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          // 固定端口优先显示，较长的账号和会话名仍可在后方省略。
          Text(server.useMosh && !server.p2pEndpoint && server.moshPort > 0 ?
            'Mosh · UDP ' + server.moshPort + ' · ' + server.username +
            (server.zellijSession ? ' · ' + server.zellijSession : '') :
            server.username + (server.zellijSession ? ' · ' + server.zellijSession : '') +
            (server.useMosh ? ' · Mosh' : ' · SSH'))
          .fontFamily(APP_FONT).fontSize(12).fontColor(MUTED)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Button('编辑', { type: ButtonType.Normal })
        .height(40).borderRadius(8).fontFamily(APP_FONT).fontSize(13)
        .fontColor(FOREGROUND).backgroundColor(BACKGROUND)
        .onClick(() => this.useSavedServer(server.id, true))
      Button('连接', { type: ButtonType.Normal })
        .height(40).borderRadius(8).fontFamily(APP_FONT).fontSize(13)
        .fontColor(BACKGROUND).backgroundColor(ACCENT)
        .onClick(() => this.useSavedServer(server.id, false))
    }.width('100%').padding(12).borderRadius(10).backgroundColor(SURFACE)
  }

  @Builder
  savedServerList() {
    Row({ space: 8 }) {
      Text('主机列表').layoutWeight(1).fontFamily(APP_FONT).fontSize(20)
        .fontWeight(FontWeight.Medium).fontColor(FOREGROUND)
      Button('添加服务器', { type: ButtonType.Normal })
        .height(40).borderRadius(8).fontFamily(APP_FONT).fontSize(13)
        .fontColor(BACKGROUND).backgroundColor(ACCENT)
        .onClick(() => this.setServerEditor(true))
    }.width('100%')
    this.connectionError()
    if (this.checkingHostKey) {
      Text('正在核对主机').fontFamily(APP_FONT).fontColor(MUTED).fontSize(14)
    }
    if (this.serverListUnavailable) {
      Row({ space: 8 }) {
        Text('暂时无法读取已保存的服务器').layoutWeight(1)
          .fontFamily(APP_FONT).fontColor(ERROR).fontSize(13)
        Button('重试', { type: ButtonType.Normal })
          .height(36).borderRadius(8).fontFamily(APP_FONT).fontSize(13)
          .fontColor(FOREGROUND).backgroundColor(SURFACE)
          .onClick(() => this.loadSavedServers())
      }.width('100%')
    } else if (this.savedServers.length === 0) {
      Text(this.managingServers ? '正在读取主机…' : '暂无已保存的服务器')
        .width('100%').padding({ top: 28, bottom: 28 }).borderRadius(10)
        .fontFamily(APP_FONT).fontSize(14).fontColor(MUTED).textAlign(TextAlign.Center)
        .backgroundColor(SURFACE)
    }
    ForEach(this.savedServers, (server: SavedSshServer) => {
      this.savedServerRow(server)
    }, (server: SavedSshServer): string => String(server.id))
  }

  @Builder
  serverFields() {
    this.field('名称（可选）', this.serverAlias, '例如 我的 WSL', InputType.Normal, 128,
      (value: string) => { this.serverAlias = value; })
    this.field('P2P 配对地址（可选）', this.p2pCode, '粘贴 nerve pair 的输出', InputType.Password, 512,
      (value: string) => { this.p2pCode = value; })
    if (!this.p2pCode.trim()) {
      this.field('主机地址', this.host, '例如 dev.example.local', InputType.Normal, 253,
        (value: string) => { this.host = value; })
    }
    Row({ space: 10 }) {
      Column() {
        this.field('用户名', this.username, 'SSH 用户', InputType.Normal, 128,
          (value: string) => { this.username = value; })
      }.layoutWeight(2)
      if (!this.p2pCode.trim()) {
        Column() {
          this.field('SSH 端口', this.port, '22', InputType.Number, 5,
            (value: string) => { this.port = value; })
        }.layoutWeight(1)
      }
    }.width('100%')
    this.field('Zellij 会话', this.zellijSession, '可选 · 留空打开 Shell', InputType.Normal, 128,
      (value: string) => { this.zellijSession = value; })
    Row({ space: 8 }) {
      this.optionButton({ label: 'SSH', selected: !this.useMosh, onSelect: () => { this.useMosh = false; } })
      this.optionButton({ label: 'Mosh', selected: this.useMosh, onSelect: () => { this.useMosh = true; } })
    }.width('100%')
    if (this.useMosh && !this.p2pCode.trim()) {
        this.field('Mosh UDP 端口', this.moshPortInput, '填写固定端口 · 留空自动分配', InputType.Number, 5,
        (value: string) => { this.moshPortInput = value; })
    }
    Row({ space: 8 }) {
      this.optionButton({ label: '密码', selected: !this.usePrivateKey, onSelect: () => this.changeAuth(false) })
      this.optionButton({ label: '私钥', selected: this.usePrivateKey, onSelect: () => this.changeAuth(true) })
    }.width('100%')
    if (this.usePrivateKey) {
      Button(this.keySelected ? '已选私钥 · 更换' : this.canKeepSavedCredentials() ? '已保存私钥 · 更换' : '选择私钥文件',
        { type: ButtonType.Normal })
        .width('100%').height(44).borderRadius(10).fontFamily(APP_FONT)
        .fontColor(FOREGROUND).backgroundColor(SURFACE)
        .onClick(() => { this.selectKey(); })
      if (this.keySelected || !this.canKeepSavedCredentials()) {
        this.field('私钥口令', this.passphrase, '未加密时留空', InputType.Password, 1024,
          (value: string) => { this.passphrase = value; })
      }
    } else {
      this.field('SSH 密码', this.password, this.canKeepSavedCredentials() ? '留空保留已保存密码' : '输入密码',
        InputType.Password, 1024, (value: string) => { this.password = value; })
    }
    this.connectionError()
    Row({ space: 10 }) {
      Button(this.editingServer ? '保存修改' : '保存服务器', { type: ButtonType.Normal })
        .layoutWeight(1).height(48).borderRadius(10).fontFamily(APP_FONT).fontSize(16)
        .fontColor(this.editingServer ? BACKGROUND : FOREGROUND)
        .backgroundColor(this.editingServer ? ACCENT : SURFACE)
        .onClick(() => this.saveServer())
      if (this.editingServer) {
        Button('删除服务器', { type: ButtonType.Normal })
          .layoutWeight(1).height(48).borderRadius(10).fontFamily(APP_FONT).fontSize(16)
          .fontColor(ERROR).backgroundColor(SURFACE)
          .onClick(() => this.removeServer())
      } else {
        Button(this.checkingHostKey ? '正在核对主机' :
          this.pushLink && !this.notificationServer ? '连接并打开会话' : '连接',
          { type: ButtonType.Normal })
          .layoutWeight(1).height(48).borderRadius(10).fontFamily(APP_FONT).fontSize(16)
          .fontWeight(FontWeight.Medium).fontColor(BACKGROUND).backgroundColor(ACCENT)
          .onClick(() => this.startConnection(undefined, this.notificationServer ? '' : this.pushLink))
      }
    }.width('100%')
  }

  @Builder
  notificationCard() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text('通知关联会话').fontFamily(APP_FONT).fontSize(15).fontColor(FOREGROUND)
          if (this.notificationServer) {
            Text(this.notificationServer.username + '@' +
              this.knownHostId(this.notificationServer.host, this.notificationServer.port))
              .fontFamily(APP_FONT).fontSize(13).fontColor(MUTED).wordBreak(WordBreak.BREAK_ALL)
          } else if (this.serverEditorOpen && !this.editingServer) {
            Text('填写发送通知的开发机信息后连接').fontFamily(APP_FONT).fontSize(13).fontColor(MUTED)
          } else if (this.savedServers.length === 0) {
            Text('点「添加服务器」填写开发机信息').fontFamily(APP_FONT).fontSize(13).fontColor(MUTED)
          } else {
            Text('选择发送通知的开发机').fontFamily(APP_FONT).fontSize(13).fontColor(MUTED)
          }
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('取消', { type: ButtonType.Normal })
          .fontFamily(APP_FONT).fontSize(13).fontColor(FOREGROUND).backgroundColor(BACKGROUND)
          .borderRadius(8).height(34)
          .onClick(() => { AppStorage.set<string>('nervePushLink', ''); })
      }.width('100%')
      if (this.notificationServer) {
        Button('打开会话', { type: ButtonType.Normal })
          .width('100%').height(44).borderRadius(8).fontFamily(APP_FONT).fontSize(15)
          .fontColor(BACKGROUND).backgroundColor(ACCENT)
          .onClick(() => this.openMatchedNotification())
      }
    }.width('100%').padding(12).borderRadius(10).backgroundColor(SURFACE)
  }

  @Builder
  serversPage() {
    Scroll() {
      Column({ space: 14 }) {
        Row({ space: 12 }) {
          if (!this.serverEditorOpen) {
            Text('>_').width(44).height(42).borderRadius(10).backgroundColor(SURFACE)
              .fontSize(18).fontFamily(APP_FONT).fontColor(ACCENT).textAlign(TextAlign.Center)
          }
          Text(this.serverEditorOpen ? (this.editingServer ? '编辑服务器' : '添加服务器') : 'Nerve')
            .layoutWeight(1).fontFamily(APP_FONT).fontSize(25).fontWeight(FontWeight.Bold).fontColor(FOREGROUND)
          Button(this.serverEditorOpen ? '返回' : '推送通知', { type: ButtonType.Normal })
            .fontFamily(APP_FONT).fontSize(13).fontColor(FOREGROUND).backgroundColor(SURFACE)
            .borderRadius(8).height(36)
            .onClick(() => {
              if (this.serverEditorOpen) {
                this.setServerEditor(false);
              } else {
                this.pushSettingsVisible = true;
              }
            })
        }.width('100%').margin({ bottom: 8 })
        if (this.pushLink) {
          this.notificationCard()
        }
        if (this.serverEditorOpen) {
          this.serverFields()
        } else {
          this.savedServerList()
        }
      }
      .padding({ left: 20, top: 18, right: 20, bottom: 28 })
      .alignItems(HorizontalAlign.Start)
      .constraintSize({ maxWidth: 540 })
      .width('100%')
      .enabled(!this.checkingHostKey && !this.managingServers)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
  }

  @Builder
  hostKeyFingerprint(label: string, value: string) {
    Column({ space: 6 }) {
      Text(label).fontFamily(APP_FONT).fontSize(13).fontColor(MUTED)
      Text(value).fontFamily(APP_FONT).fontSize(14).fontColor(FOREGROUND)
        .wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12).borderRadius(10).backgroundColor(SURFACE)
  }

  @Builder
  reviewHostKey(review: HostKeyReview) {
    Scroll() {
      Column({ space: 14 }) {
        Text(review.previous ? 'SSH 主机密钥已变化' : '首次连接此主机')
          .fontFamily(APP_FONT).fontSize(24).fontWeight(FontWeight.Bold)
          .fontColor(review.previous ? ERROR : FOREGROUND)
        Text(this.knownHostId(review.host, review.port)).fontFamily(APP_FONT).fontSize(15).fontColor(FOREGROUND)
          .wordBreak(WordBreak.BREAK_ALL)
        Text(review.previous ?
          '连接已阻止。请在开发机或可信渠道核对新指纹。' + (review.reconnect ? '' : '更新信任后，需要重新填写 SSH 凭据。') :
          '请确认这是你的开发机。确认后，Nerve 会在此设备记住它的主机密钥。')
          .fontFamily(APP_FONT).fontSize(14).fontColor(MUTED)
        if (review.previous) {
          this.hostKeyFingerprint('已保存的指纹', review.previous)
        }
        this.hostKeyFingerprint(review.previous ? '新指纹' : '主机指纹', review.observed)
        if (this.errorText) {
          Text(this.errorText).fontFamily(APP_FONT).fontSize(14).fontColor(ERROR)
        }
        Row({ space: 10 }) {
          Button('取消', { type: ButtonType.Normal })
            .layoutWeight(1).height(44).borderRadius(10).fontFamily(APP_FONT).fontSize(15)
            .fontColor(FOREGROUND).backgroundColor(SURFACE)
            .onClick(() => this.cancelHostKeyReview())
          Button(review.previous ? review.reconnect ? '更新并连接' : '更新信任' : '信任并连接',
            { type: ButtonType.Normal })
            .layoutWeight(1).height(44).borderRadius(10).fontFamily(APP_FONT).fontSize(15)
            .fontColor(BACKGROUND).backgroundColor(ACCENT)
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
      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text(this.openedRemoteTitle)
            .fontFamily(APP_FONT).fontSize(17).fontWeight(FontWeight.Medium).fontColor(FOREGROUND).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.statusText).fontFamily(APP_FONT).fontSize(12).fontColor(this.connected ? ACCENT : MUTED)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.pushLink && this.pushLink !== this.openedPushLink) {
          Button(this.notificationServer ? '打开会话' : '查看通知', { type: ButtonType.Normal })
            .height(34).borderRadius(8).fontFamily(APP_FONT).fontSize(13)
            .fontColor(BACKGROUND).backgroundColor(ACCENT)
            .enabled(!this.managingServers && !this.closingMosh)
            .onClick(() => {
              if (this.notificationServer) {
                this.openMatchedNotification();
              } else {
                this.closeTerminal(() => this.backToForm());
              }
            })
        }
        this.terminalMenuButton(ACCENT)
      }.width('100%').padding({ left: 12, top: 8, right: 12, bottom: 8 })
      Web({ src: $rawfile('terminal/index.html'), controller: this.view })
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('#0d1418')
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
          if (this.generation === instance) this.runTerminalScript('window.nerveTerminal.start()');
        })
        .onRenderExited(() => {
          if (this.generation === instance) this.onTerminalError();
        })
      if (this.errorText) {
        Text(this.errorText).width('100%').fontFamily(APP_FONT).fontColor(ERROR).fontSize(13)
          .padding({ left: 12, right: 12, top: 6 })
      }
      Row({ space: 5 }) {
        Button('Ctrl', { type: ButtonType.Normal })
          .layoutWeight(1).padding(0).height(38).borderRadius(8).fontSize(14)
          .fontFamily(APP_FONT)
          .fontColor(this.ctrlArmed ? BACKGROUND : FOREGROUND)
          .backgroundColor(this.ctrlArmed ? ACCENT : SURFACE)
          .focusOnTouch(false)
          .enabled(this.connected)
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
      }.padding({ left: 8, top: 6, right: 8, bottom: 8 }).width('100%')
    }.width('100%').height('100%')
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
        PushSettings({ onClose: () => { this.pushSettingsVisible = false; } })
      } else {
        this.serversPage()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BACKGROUND)
  }
}
