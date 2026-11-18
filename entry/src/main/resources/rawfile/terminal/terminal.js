'use strict';

const FONT_FAMILY = 'Maple Mono';
const FONT_SIZE = 14;
const terminal = new Terminal({
  fontFamily: `"${FONT_FAMILY}", monospace`,
  fontSize: FONT_SIZE,
  scrollback: 1500,
  cursorBlink: true,
  theme: { background: '#0d1418', foreground: '#e3eced', cursor: '#7ae0bb', selectionBackground: '#334e53' },
  // 远端内容可以显示超链接，点击不会导航或打开其他窗口。
  linkHandler: { activate() {} }
});
const fit = new FitAddon.FitAddon();
const container = document.getElementById('terminal');
terminal.loadAddon(fit);

let native = null;
let fitFrame = 0;
const keys = { escape: '\x1b', tab: '\t', enter: '\r', up: 'A', down: 'B', right: 'C', left: 'D' };

function sendSize() {
  if (!native || !container.clientWidth || !container.clientHeight) {
    return;
  }
  fit.fit();
  native.onSize(terminal.cols, terminal.rows);
}

// 旋转、窗口和软键盘变化都使用实际可见网格更新 PTY。
new ResizeObserver(() => {
  cancelAnimationFrame(fitFrame);
  fitFrame = requestAnimationFrame(sendSize);
}).observe(container);

terminal.onData(text => {
  if (native) native.onInput(text);
});
terminal.onBinary(bytes => {
  if (native) native.onBinary(btoa(bytes));
});

window.nerveTerminal = {
  async start() {
    // 字体就绪后再打开终端，首次字符测量与 SSH 请求使用同一套网格。
    try {
      await document.fonts.load(`${FONT_SIZE}px "${FONT_FAMILY}"`);
    } catch {
      console.warn('无法加载内置 Maple Mono 字体，将使用等宽字体。');
    }
    if (terminal.element) return;
    terminal.open(container);
    native = window.nerveHost;
    sendSize();
  },
  write(encoded) {
    const raw = atob(encoded);
    const bytes = Uint8Array.from(raw, ch => ch.charCodeAt(0));
    // 写入回调在 xterm 解析完成后释放背压，避免连续输出塞满浏览器队列。
    terminal.write(bytes, () => native.onOutputFlushed());
  },
  focus() {
    terminal.focus();
  },
  key(name) {
    if (!Object.hasOwn(keys, name) || !native) return;
    const value = keys[name];
    const arrow = value.length === 1 && value >= 'A' && value <= 'D';
    const prefix = terminal.modes.applicationCursorKeysMode ? '\x1bO' : '\x1b[';
    native.onInput(arrow ? prefix + value : value);
  }
};
