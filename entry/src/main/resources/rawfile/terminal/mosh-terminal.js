'use strict';

// Web 只作协议计算和渲染，收发都经过只绑定到已认证主机的原生 UDP 句柄。
const MOSH_ASSET_CHUNK = 64 * 1024;
const MOSH_TICK_MS = 30;
const MOSH_WAIT_MS = 6500;
const MOSH_REBIND_MS = 8000;
const MOSH_MAX_SNAPSHOTS = 128;
const MOSH_MAX_SNAPSHOT_CHARS = 6 * 1024 * 1024;
const MOSH_MAX_PENDING_STATES = 32;
const MOSH_RENDER_FALLBACK_MS = 100;

function moshDecode(encoded) {
  return Uint8Array.from(atob(encoded), byte => byte.charCodeAt(0));
}

class MoshTerminal {
  constructor(terminal, host) {
    this.terminal = terminal;
    this.host = host;
    this.serializer = new SerializeAddon.SerializeAddon();
    this.terminal.loadAddon(this.serializer);
    this.terminal.options.scrollback = 0;
    this.snapshots = new Map([[0n, { ansi: '', columns: 80, rows: 24 }]]);
    this.snapshotChars = 0;
    this.displayed = 0n;
    this.updates = [];
    this.rendering = false;
    this.lastPacketAt = 0;
    this.lastProbeAt = 0;
    this.status = '';
    this.closing = false;
    this.engine = undefined;
    this.timer = undefined;
  }

  async start(columns, rows) {
    // 仅从打包资源读取 WASM，保持 ArkWeb 的网络和文件访问禁用。
    const chunks = [];
    let length = 0;
    for (let offset = 0; ; offset += MOSH_ASSET_CHUNK) {
      const encoded = this.host.onMoshWasm(offset);
      if (!encoded) break;
      const chunk = moshDecode(encoded);
      chunks.push(chunk);
      length += chunk.length;
    }
    const wasm = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) {
      wasm.set(chunk, offset);
      offset += chunk.length;
    }
    const runner = new Go();
    const { instance } = await WebAssembly.instantiate(wasm, runner.importObject);
    runner.run(instance).catch(() => this.finish('error'));
    this.engine = window.nerveMoshEngine(this.host.onMoshKey());
    if (!this.engine) throw new Error('Mosh 密钥格式无效');
    this.lastPacketAt = performance.now();
    this.lastProbeAt = this.lastPacketAt;
    this.engine.resize(columns, rows);
    this.timer = setInterval(() => this.tick(), MOSH_TICK_MS);
    this.tick();
  }

  notify(status) {
    if (this.status !== status) {
      this.status = status;
      this.host.onMoshState(status);
    }
  }

  tick() {
    if (!this.engine) return;
    const now = performance.now();
    if (!this.closing && now - this.lastPacketAt >= MOSH_WAIT_MS) {
      this.notify('waiting');
      if (now - this.lastProbeAt >= MOSH_REBIND_MS) {
        // 换套接字后继续使用原来的密钥和状态序号，服务端会跟到新的来源。
        this.host.onMoshRebind();
        this.engine.probe();
        this.lastProbeAt = now;
      }
    }
    for (const datagram of this.engine.tick() || []) {
      this.host.onMoshDatagram(btoa(String.fromCharCode(...datagram)));
    }
  }

  pump(packets, input, columns, rows) {
    if (!this.engine) return false;
    for (const encoded of packets) {
      // 解析器积压时先等待 xterm，未交给协议引擎的包由对端重发。
      if (this.updates.length >= MOSH_MAX_PENDING_STATES) break;
      const update = this.engine.receive(moshDecode(encoded));
      if (!update) continue;
      this.lastPacketAt = performance.now();
      if (update.closed) {
        this.finish('closed');
        return false;
      }
      if (!this.closing) this.notify('online');
      if (update !== true) this.updates.push(update);
    }
    this.paint();
    if (!this.engine || this.closing) return false;
    if (columns && rows) this.engine.resize(columns, rows);
    const accepted = !input || this.engine.input(moshDecode(input));
    this.tick();
    return accepted;
  }

  paint() {
    if (this.rendering || !this.updates.length) return;
    const update = this.updates.shift();
    const from = BigInt(update.from);
    const state = BigInt(update.state);
    const base = this.snapshots.get(from);
    if (!base) {
      this.finish('error');
      return;
    }
    this.rendering = true;
    const restoring = from !== this.displayed;
    const previousScreen = restoring ? this.holdScreen() : undefined;
    const apply = () => {
      if (update.columns && update.rows) this.terminal.resize(update.columns, update.rows);
      this.terminal.write(update.screen, () => {
        const snapshot = {
          ansi: update.screen.length || update.columns ? this.serializer.serialize({ scrollback: 0 }) : base.ansi,
          columns: this.terminal.cols,
          rows: this.terminal.rows
        };
        this.snapshots.set(state, snapshot);
        this.snapshotChars += snapshot.ansi.length;
        this.displayed = state;
        // 按服务端声明丢弃快照，同时限制短时间内未确认的屏幕数。
        const discardBefore = BigInt(update.discardBefore);
        for (const key of this.snapshots.keys()) {
          if (key < discardBefore) this.dropSnapshot(key);
        }
        while (this.snapshots.size > 1 &&
          (this.snapshots.size > MOSH_MAX_SNAPSHOTS || this.snapshotChars > MOSH_MAX_SNAPSHOT_CHARS)) {
          this.dropSnapshot(this.snapshots.keys().next().value);
        }
        this.showScreen(previousScreen, () => {
          this.rendering = false;
          if (update.ended) {
            this.tick();
            this.finish(this.closing ? 'closed' : 'ended');
          } else {
            this.paint();
          }
        });
      });
    };
    if (!restoring) {
      apply();
    } else {
      // 服务端可能依据较早的屏幕生成差量，先按旧网格恢复再应用更新。
      this.terminal.reset();
      this.terminal.resize(base.columns, base.rows);
      this.terminal.write(base.ansi, apply);
    }
  }

  holdScreen() {
    const screen = this.terminal.element?.querySelector('.xterm-screen');
    const parent = screen?.parentElement;
    if (!parent) return undefined;

    // xterm 复位和光标刷新都可能画出中间状态，先保留一份实际显示的画面。
    const previous = document.createElement('div');
    previous.className = 'nerve-mosh-previous-screen';
    previous.setAttribute('aria-hidden', 'true');
    Object.assign(previous.style, {
      position: 'absolute',
      inset: '0',
      zIndex: '3',
      overflow: 'hidden',
      pointerEvents: 'none',
      backgroundColor: this.terminal.options.theme?.background ?? '#000000'
    });
    const copy = screen.cloneNode(true);
    Object.assign(copy.style, {
      position: 'absolute',
      left: screen.offsetLeft + 'px',
      top: screen.offsetTop + 'px'
    });
    previous.appendChild(copy);
    parent.appendChild(previous);
    return previous;
  }

  showScreen(previous, done) {
    if (!previous) {
      done();
      return;
    }
    const reveal = () => {
      clearTimeout(timeout);
      render.dispose();
      previous.remove();
      done();
    };
    const render = this.terminal.onRender(reveal);
    // WebView 暂时不可见时可能没有绘制事件，到期后释放队列。
    const timeout = setTimeout(reveal, MOSH_RENDER_FALLBACK_MS);
    this.terminal.refresh(0, this.terminal.rows - 1);
  }

  dropSnapshot(state) {
    this.snapshotChars -= this.snapshots.get(state).ansi.length;
    this.snapshots.delete(state);
  }

  close() {
    if (!this.engine) {
      this.finish('closed');
      return;
    }
    this.closing = true;
    this.engine.shutdown();
    this.tick();
  }

  finish(status) {
    clearInterval(this.timer);
    this.engine = undefined;
    this.updates = [];
    this.notify(status);
  }
}
