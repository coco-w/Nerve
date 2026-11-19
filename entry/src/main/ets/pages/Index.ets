import { webview } from '@kit.ArkWeb';
import { preferences } from '@kit.ArkData';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { connect, disconnect, probeHostKey, read, resize, SshConnectOptions, SshError, SshHandle, write }
  from 'libnerve_ssh.so';
import { PushSettings } from '../push/PushSettings';
import { ACCENT, APP_FONT, BACKGROUND, ERROR, FOREGROUND, MUTED, SURFACE } from '../ui/Theme';

// ArkWeb 拦截时使用资源 URL，加载后可能显示为 RAWFILE 格式。
const TERMINAL_URL = 'resource://rawfile/terminal/index.html';
const TERMINAL_LOADED_URL = 'resource:/RAWFILE/terminal/index.html';
const TERMINAL_FILE_URL = 'file:///data/storage/el1/bundle/entry/resources/rawfile/terminal/index.html';
const POLL_MS = 30;
const MAX_CHUNK_BYTES = 16 * 1024;
const MAX_QUEUED_BYTES = 64 * 1024;
const MAX_KEY_BYTES = 32 * 1024;
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
}

// 渲染层只传终端输入、尺寸和渲染确认，连接信息及凭据由 ArkTS 持有。
class TerminalBridge {
  private readonly input: (text: string) => void;
  private readonly binaryInput: (encoded: string) => void;
  private readonly size: (columns: number, rows: number) => void;
  private readonly outputFlushed: () => void;

  constructor(input: (text: string) => void, binaryInput: (encoded: string) => void,
    size: (columns: number, rows: number) => void, outputFlushed: () => void) {
    this.input = input;
    this.binaryInput = binaryInput;
    this.size = size;
    this.outputFlushed = outputFlushed;
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
}

@Entry
@Component
struct Index {
  @StorageProp('nervePushLink') @Watch('onPushLinkChanged') private pushLink: string = '';
  @State private pushSettingsVisible: boolean = false;
  @State private openedPushLink: string = '';
  @State private host: string = '';
  @State private port: string = '22';
  @State private username: string = '';
  @State private zellijSession: string = '';
  @State private usePrivateKey: boolean = false;
  @State private keySelected: boolean = false;
  @State private password: string = '';
  @State private passphrase: string = '';
  @State private checkingHostKey: boolean = false;
  @State private hostKeyReview: HostKeyReview | undefined = undefined;
  @State private terminalVisible: boolean = false;
  @State private connected: boolean = false;
  @State private statusText: string = '';
  @State private errorText: string = '';
  @State private ctrlArmed: boolean = false;

  private privateKey: string = '';
  private formKeyboardMode: KeyboardAvoidMode = KeyboardAvoidMode.OFFSET;
  private view = new webview.WebviewController();
  private readonly encoder = new util.TextEncoder();
  private readonly base64 = new util.Base64Helper();
  private bridge = this.createBridge(0);

  // 连接代次会在退出时增加，丢弃此前未完成的握手和渲染回调。
  private generation: number = 0;
  private connection: SshHandle | undefined;
  // 首次确认前暂存本次表单，取消后丢弃，凭据始终留在内存中。
  private pendingTrustConnection: SshConnectOptions | undefined;
  private pendingConnection: SshConnectOptions | undefined;
  private loadTimer: number = -1;
  private ioTimer: number = -1;
  private inputQueue: Array<ArrayBuffer> = [];
  private inputOffset: number = 0;
  private queuedBytes: number = 0;
  private writePending: boolean = false;
  private renderPending: boolean = false;
  private latestSize: PtySize = { columns: 80, rows: 24 };
  private sentSize: PtySize = { columns: 80, rows: 24 };
  private resizePending: PtySize | undefined;

  aboutToAppear(): void {
    this.getUIContext().getFont().registerFont({
      familyName: APP_FONT,
      familySrc: $rawfile('fonts/MapleMono-NF-CN-Regular.ttf')
    });
  }

  onBackPress(): boolean {
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
    if (!this.terminalVisible) {
      return false;
    }
    this.backToForm();
    return true;
  }

  private onPushLinkChanged(): void {
    if (this.pushLink) this.pushSettingsVisible = false;
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

  private async startConnection(): Promise<void> {
    if (this.terminalVisible || this.hostKeyReview || this.checkingHostKey) {
      return;
    }
    const host = this.host.trim().replace(/^\[([^\]]+)\]$/, '$1');
    const username = this.username.trim();
    const port = Number(this.port);
    // 通知只引用本地事件，通过已校验指纹的 SSH 连接到对应开发机后才解析会话。
    const pushLink = this.pushLink;
    const session = pushLink ? '' : this.zellijSession.trim();
    if (!host || !username || !/^\d{1,5}$/.test(this.port) || port < 1 || port > 65535) {
      this.errorText = '请填写主机地址、用户名和 1–65535 范围内的端口。';
      return;
    }
    if (session && !/^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/.test(session)) {
      this.errorText = '会话名可使用字母、数字、下划线、点和连字符。留空后可在终端中手动附接。';
      return;
    }
    if ((this.usePrivateKey && !this.keySelected) || (!this.usePrivateKey && !this.password)) {
      this.errorText = this.usePrivateKey ? '请选择 SSH 私钥。' : '请输入 SSH 密码。';
      return;
    }

    const options: SshConnectOptions = {
      host, port, username, fingerprint: '', password: this.password, privateKey: this.privateKey,
      passphrase: this.passphrase, zellijSession: session, pushLink, columns: 80, rows: 24
    };
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
        this.beginConnection(options);
        return;
      }
      // 首次握手只取指纹，确认前不向主机发送用户名或凭据。
      const observed = await probeHostKey({ host, port });
      if (this.generation === generation) {
        this.pendingTrustConnection = options;
        this.hostKeyReview = { host, port, observed, previous: '' };
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
      const options = this.pendingTrustConnection;
      this.pendingTrustConnection = undefined;
      this.hostKeyReview = undefined;
      if (options) {
        options.fingerprint = review.observed;
        this.beginConnection(options);
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

  private beginConnection(options: SshConnectOptions): void {
    this.checkingHostKey = false;
    this.pendingConnection = options;
    this.openedPushLink = options.pushLink;
    this.clearCredentials();
    this.errorText = '';
    const generation = ++this.generation;
    this.statusText = '正在打开终端';
    this.view = new webview.WebviewController();
    this.bridge = this.createBridge(generation);
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
    return new TerminalBridge(
      (text: string) => { if (this.generation === generation) this.queueText(text); },
      (encoded: string) => { if (this.generation === generation) this.queueBinary(encoded); },
      (columns: number, rows: number) => {
        if (this.generation === generation) this.onTerminalSize(columns, rows);
      },
      () => { if (this.generation === generation) this.renderPending = false; }
    );
  }

  private onTerminalSize(columns: number, rows: number): void {
    if (!this.terminalVisible || !Number.isInteger(columns) || !Number.isInteger(rows) || columns < 2 || rows < 2) {
      return;
    }
    this.latestSize = { columns: Math.min(columns, 500), rows: Math.min(rows, 500) };
    const options = this.pendingConnection;
    if (options) {
      this.pendingConnection = undefined;
      clearTimeout(this.loadTimer);
      this.loadTimer = -1;
      options.columns = this.latestSize.columns;
      options.rows = this.latestSize.rows;
      this.sentSize = this.latestSize;
      this.openConnection(options, this.generation);
    }
  }

  private async openConnection(options: SshConnectOptions, generation: number): Promise<void> {
    try {
      this.statusText = '正在连接 SSH';
      const opening = connect(options);
      // 原生模块同步复制所需参数，后台握手期间不再持有表单副本。
      options.password = '';
      options.privateKey = '';
      options.passphrase = '';
      const connection = await opening;
      if (this.generation !== generation) {
        disconnect(connection);
        return;
      }
      this.connection = connection;
      this.connected = true;
      this.statusText = 'SSH 已连接';
      this.ioTimer = setInterval(() => this.pumpTerminal(), POLL_MS);
    } catch (error) {
      if (this.generation === generation) {
        const failure = error as SshError;
        if (failure.fingerprint) {
          // 原生层已在用户认证前断开，须明确确认新密钥才能再次登录。
          this.backToForm();
          this.hostKeyReview = {
            host: options.host, port: options.port, observed: failure.fingerprint, previous: options.fingerprint
          };
        } else {
          this.failOpening(failure.message || 'SSH 连接失败。');
        }
      }
    }
  }

  private failOpening(message: string): void {
    this.backToForm();
    this.errorText = message;
  }

  private backToForm(): void {
    this.stopConnection();
    this.terminalVisible = false;
    this.getUIContext().setKeyboardAvoidMode(this.formKeyboardMode);
    this.errorText = '';
  }

  private stopConnection(): void {
    this.generation++;
    clearTimeout(this.loadTimer);
    clearInterval(this.ioTimer);
    this.loadTimer = -1;
    this.ioTimer = -1;
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

  private pumpTerminal(): void {
    const connection = this.connection;
    if (!connection) {
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
        this.stopConnection();
        this.statusText = '远端已断开';
        return;
      }
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
    if (this.connected) {
      this.stopConnection();
      this.statusText = 'SSH 已断开';
      this.errorText = '终端显示中断，请重新连接。';
    } else if (this.terminalVisible) {
      this.failOpening('无法加载内置终端，请重试。');
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
  authButton(label: string, useKey: boolean) {
    Button(label, { type: ButtonType.Normal })
      .layoutWeight(1)
      .height(38)
      .borderRadius(8)
      .fontFamily(APP_FONT)
      .fontSize(14)
      .fontColor(this.usePrivateKey === useKey ? BACKGROUND : FOREGROUND)
      .backgroundColor(this.usePrivateKey === useKey ? ACCENT : SURFACE)
      .onClick(() => this.changeAuth(useKey))
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
  connectionForm() {
    Scroll() {
      Column({ space: 14 }) {
        Row({ space: 12 }) {
          Text('>_')
            .fontSize(18)
            .fontFamily(APP_FONT)
            .fontColor(ACCENT)
            .textAlign(TextAlign.Center)
            .width(44)
            .height(42)
            .backgroundColor(SURFACE)
            .borderRadius(10)
          Column({ space: 2 }) {
            Text('Nerve').fontFamily(APP_FONT).fontSize(25).fontWeight(FontWeight.Bold).fontColor(FOREGROUND)
            Text('SSH 连接').fontFamily(APP_FONT).fontSize(13).fontColor(MUTED)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button('推送通知', { type: ButtonType.Normal })
            .fontFamily(APP_FONT).fontSize(13).fontColor(FOREGROUND).backgroundColor(SURFACE)
            .borderRadius(8).height(36)
            .onClick(() => { this.pushSettingsVisible = true; })
        }.width('100%').margin({ bottom: 8 })
        if (this.pushLink) {
          Row({ space: 10 }) {
            Column({ space: 4 }) {
              Text('通知关联会话').fontFamily(APP_FONT).fontSize(15).fontColor(FOREGROUND)
              Text('连接触发通知的开发机 · ' + this.pushLink.slice(0, 8))
                .fontFamily(APP_FONT).fontSize(12).fontColor(MUTED)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button('取消', { type: ButtonType.Normal })
              .fontFamily(APP_FONT).fontSize(13).fontColor(FOREGROUND).backgroundColor(BACKGROUND)
              .borderRadius(8).height(34)
              .onClick(() => { AppStorage.set<string>('nervePushLink', ''); })
          }.width('100%').padding(12).borderRadius(10).backgroundColor(SURFACE)
        }
        this.field('主机地址', this.host, '例如 dev.example.local', InputType.Normal, 253,
          (value: string) => { this.host = value; })
        Row({ space: 10 }) {
          Column() {
            this.field('用户名', this.username, 'SSH 用户', InputType.Normal, 128,
              (value: string) => { this.username = value; })
          }.layoutWeight(2)
          Column() {
            this.field('端口', this.port, '22', InputType.Number, 5,
              (value: string) => { this.port = value; })
          }.layoutWeight(1)
        }.width('100%')
        if (!this.pushLink) {
          this.field('Zellij 会话', this.zellijSession, '可选 · 留空打开 Shell', InputType.Normal, 128,
            (value: string) => { this.zellijSession = value; })
        }
        Row({ space: 8 }) {
          this.authButton('密码', false)
          this.authButton('私钥', true)
        }.width('100%')
        if (this.usePrivateKey) {
          Button(this.keySelected ? '已选私钥 · 更换' : '选择私钥文件', { type: ButtonType.Normal })
            .width('100%')
            .height(44)
            .borderRadius(10)
            .fontFamily(APP_FONT)
            .fontColor(FOREGROUND)
            .backgroundColor(SURFACE)
            .onClick(() => { this.selectKey(); })
          this.field('私钥口令', this.passphrase, '未加密时留空', InputType.Password, 1024,
            (value: string) => { this.passphrase = value; })
        } else {
          this.field('SSH 密码', this.password, '输入密码', InputType.Password, 1024,
            (value: string) => { this.password = value; })
        }
        if (this.errorText) {
          Text(this.errorText).fontFamily(APP_FONT).fontColor(ERROR).fontSize(14)
            .width('100%').copyOption(CopyOptions.LocalDevice)
        }
        Button(this.checkingHostKey ? '正在核对主机' : this.pushLink ? '连接并打开会话' : '连接',
          { type: ButtonType.Normal })
          .width('100%')
          .height(48)
          .borderRadius(10)
          .fontFamily(APP_FONT)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(BACKGROUND)
          .backgroundColor(ACCENT)
          .onClick(() => this.startConnection())
      }
      .padding({ left: 20, top: 18, right: 20, bottom: 28 })
      .alignItems(HorizontalAlign.Start)
      .constraintSize({ maxWidth: 540 })
      .width('100%')
      .enabled(!this.checkingHostKey)
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
        Text(review.previous ? '连接已阻止。请在开发机或可信渠道核对新指纹。更新信任后，需要重新填写 SSH 凭据。' :
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
          Button(review.previous ? '更新信任' : '信任并连接', { type: ButtonType.Normal })
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
  terminalView() {
    Column() {
      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text(this.openedPushLink ? this.host.trim() : this.zellijSession.trim() || this.host.trim())
            .fontFamily(APP_FONT).fontSize(17).fontWeight(FontWeight.Medium).fontColor(FOREGROUND).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.statusText).fontFamily(APP_FONT).fontSize(12).fontColor(this.connected ? ACCENT : MUTED)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.pushLink && this.pushLink !== this.openedPushLink) {
          Button('查看通知', { type: ButtonType.Normal })
            .height(34).borderRadius(8).fontFamily(APP_FONT).fontSize(13)
            .fontColor(BACKGROUND).backgroundColor(ACCENT)
            .onClick(() => this.backToForm())
        }
        Button(this.connected ? '断开' : '返回', { type: ButtonType.Normal })
          .height(34).borderRadius(8).fontFamily(APP_FONT).fontSize(13)
          .fontColor(FOREGROUND).backgroundColor(SURFACE)
          .onClick(() => this.backToForm())
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
          methodList: ['onSize', 'onInput', 'onBinary', 'onOutputFlushed'],
          controller: this.view
        })
        .onLoadIntercept(event => {
          const url = event.data.getRequestUrl();
          return event.data.isMainFrame() && url !== TERMINAL_URL && url !== TERMINAL_LOADED_URL &&
            url !== TERMINAL_FILE_URL;
        })
        .onPageEnd(() => this.runTerminalScript('window.nerveTerminal.start()'))
        .onRenderExited(() => this.onTerminalError())
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
        this.terminalView()
      } else if (this.hostKeyReview) {
        this.reviewHostKey(this.hostKeyReview)
      } else if (this.pushSettingsVisible) {
        PushSettings({ onClose: () => { this.pushSettingsVisible = false; } })
      } else {
        this.connectionForm()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BACKGROUND)
  }
}
