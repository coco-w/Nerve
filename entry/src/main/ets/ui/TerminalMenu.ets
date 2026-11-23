import { APP_FONT } from './Theme';

// 终端菜单固定使用终端工具栏的深色底板，避免浅色外观下出现突兀的白色弹层。
export const NERVE_TERMINAL_MENU_BACKGROUND = '#171b2a';
const MENU_CARD = '#1b2031';
const MENU_LINE = '#2d3145';
const MENU_TEXT = '#f1f1fc';
const MENU_MUTED = '#a9b3d0';
const MENU_DANGER = '#ffb7a9';

// 会话信息跟随连接状态更新；关闭菜单与断开连接分别由父页面处理。
@Component
export struct NerveTerminalMenu {
  @Prop sessionTitle: string = '';
  @Prop statusText: string = '';
  @Prop connected: boolean = false;
  @Prop closing: boolean = false;
  @Prop accent: string = '#b6a9ff';
  onClose: () => void = () => {};
  onExit: () => void = () => {};

  build() {
    Column({ space: 18 }) {
      Row({ space: 12 }) {
        Text('终端操作').fontSize(20).fontWeight(FontWeight.Bold).fontColor(MENU_TEXT).layoutWeight(1)
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(16).fontColor([MENU_MUTED])
        }.width(44).height(44).padding(0).borderRadius(13).backgroundColor(MENU_CARD)
        .accessibilityText('关闭终端菜单').focusOnTouch(false).onClick(() => this.onClose())
      }.width('100%')
      Row({ space: 12 }) {
        Text('>_').fontFamily(APP_FONT).fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.accent)
          .textAlign(TextAlign.Center).width(42).height(42).borderRadius(12).backgroundColor('#252b40')
          .accessibilityLevel('no')
        Column({ space: 5 }) {
          Text(this.sessionTitle || '当前终端').fontFamily(APP_FONT).fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor(MENU_TEXT).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.statusText || '正在准备连接').fontSize(12)
            .fontColor(this.connected ? '#80deb3' : MENU_MUTED)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%').padding(14).borderRadius(16).backgroundColor(MENU_CARD)
      .border({ width: 1, color: MENU_LINE })
      Button({ type: ButtonType.Normal }) {
        Row({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.power')).fontSize(20)
            .fontColor([this.connected || this.closing ? MENU_DANGER : this.accent])
            .width(42).accessibilityLevel('no')
          Column({ space: 5 }) {
            Text(this.closing ? '正在断开…' : this.connected ? '断开并返回' : '返回主机列表')
              .fontSize(15).fontWeight(FontWeight.Medium)
              .fontColor(this.connected || this.closing ? MENU_DANGER : MENU_TEXT)
            Text(this.connected || this.closing ? '结束当前连接并返回主机列表' : '关闭终端并返回主机列表')
              .fontSize(12).fontColor(MENU_MUTED)
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Text('›').fontSize(22).fontColor(MENU_MUTED).accessibilityLevel('no')
        }.width('100%').padding(14)
      }.width('100%').padding(0).constraintSize({ minHeight: 76 }).borderRadius(16)
      .backgroundColor(this.connected || this.closing ? '#30252e' : MENU_CARD)
      .border({ width: 1, color: this.connected || this.closing ? '#51333e' : MENU_LINE, radius: 16 })
      .enabled(!this.closing).opacity(this.closing ? 0.6 : 1).focusOnTouch(false)
      .onClick(() => this.onExit())
    }.width('100%').constraintSize({ maxWidth: 540 })
    .padding({ left: 20, right: 20, top: 8, bottom: 28 }).alignItems(HorizontalAlign.Start)
    .backgroundColor(NERVE_TERMINAL_MENU_BACKGROUND)
  }
}
