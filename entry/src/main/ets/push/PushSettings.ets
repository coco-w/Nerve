import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { notificationManager } from '@kit.NotificationKit';
import { pushService } from '@kit.PushKit';
import { ACCENT, APP_FONT, BACKGROUND, FOREGROUND, MUTED, SURFACE } from '../ui/Theme';

function tokenFailure(code: number): string {
  switch (code) {
    case 1000900010:
      return '应用身份校验失败。请检查当前安装包的推送签名。';
    case 1000900012:
      return '当前安装包的推送权益未生效。请核对后台配置和调试 Profile。';
    case 1000900014:
      return '当前设备不支持获取推送令牌。';
    case 1000900008:
    case 1000900011:
      return '无法连接华为推送服务。请检查设备网络。';
    default:
      return '华为推送服务未返回设备令牌。';
  }
}

@Component
export struct PushSettings {
  onClose: () => void = () => {};
  @State private allowed: boolean | undefined = undefined;
  @State private permissionRequested: boolean = false;
  @State private permissionText: string = '正在读取系统通知权限…';
  @State private tokenText: string = '尚未获取';
  @State private hasToken: boolean = false;
  @State private busy: boolean = false;
  private token: string = '';
  private active: boolean = false;

  aboutToAppear(): void {
    this.active = true;
    this.refreshPermission();
  }

  aboutToDisappear(): void {
    this.active = false;
    this.token = '';
  }

  private async refreshPermission(): Promise<void> {
    try {
      this.allowed = await notificationManager.isNotificationEnabled();
      this.permissionText = this.allowed ? '已允许' : '未允许';
    } catch {
      this.allowed = undefined;
      this.permissionText = '暂时无法读取通知权限。';
    }
  }

  private async changePermission(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context || this.busy) return;
    this.busy = true;
    try {
      if (this.allowed || this.permissionRequested) {
        await notificationManager.openNotificationSettingsWithResult(context);
      } else {
        this.permissionRequested = true;
        try {
          await notificationManager.requestEnableNotification(context);
        } catch (error) {
          // 用户拒绝后保留当前状态，下次点击打开系统通知设置。
          if ((error as BusinessError).code !== 1600004) {
            throw new Error('无法请求通知授权');
          }
        }
      }
      await this.refreshPermission();
    } catch {
      this.permissionText = '无法打开授权页面，请在系统设置中检查。';
    } finally {
      this.busy = false;
    }
  }

  private async obtainToken(): Promise<void> {
    if (this.busy || this.hasToken) return;
    this.busy = true;
    this.tokenText = '正在获取…';
    try {
      const token = await pushService.getToken();
      if (!this.active) return;
      this.token = token;
      this.hasToken = token.length > 0;
      this.tokenText = this.hasToken ? '已获取，可保存到文件' : '华为推送服务返回了空令牌。';
    } catch (error) {
      if (!this.active) return;
      const code = (error as BusinessError).code;
      this.tokenText = tokenFailure(code) + (code ? '（' + code + '）' : '');
    } finally {
      this.busy = false;
    }
  }

  private async saveToken(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    const token = this.token;
    if (!context || this.busy || !token) return;
    this.busy = true;
    try {
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = ['nerve-push-token.txt'];
      const uris = await new picker.DocumentViewPicker(context).save(options);
      if (!uris.length || !this.active) return;
      // 令牌只写到用户选定的位置，页面、日志和应用首选项中均不显示明文。
      const file = await fileIo.open(uris[0], fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        await fileIo.write(file.fd, token);
      } finally {
        await fileIo.close(file);
      }
      this.tokenText = '已保存令牌文件';
    } catch {
      this.tokenText = '无法保存令牌，请重新选择保存位置。';
    } finally {
      this.busy = false;
    }
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Row({ space: 12 }) {
          Button('返回', { type: ButtonType.Normal })
            .fontFamily(APP_FONT).fontSize(14).fontColor(FOREGROUND).backgroundColor(SURFACE)
            .borderRadius(8).height(38).onClick(() => this.onClose())
          Text('推送通知').fontFamily(APP_FONT).fontSize(22).fontWeight(FontWeight.Bold).fontColor(FOREGROUND)
        }.width('100%')

        Column({ space: 8 }) {
          Text('系统通知').fontFamily(APP_FONT).fontSize(16).fontColor(FOREGROUND)
          Text(this.permissionText).fontFamily(APP_FONT).fontSize(13).fontColor(MUTED)
          Button(this.allowed || this.permissionRequested ? '通知设置' : '允许通知', { type: ButtonType.Normal })
            .fontFamily(APP_FONT).fontSize(14).fontColor(FOREGROUND).backgroundColor(BACKGROUND)
            .borderRadius(8).height(42).enabled(!this.busy).onClick(() => this.changePermission())
        }.width('100%').alignItems(HorizontalAlign.Start).padding(14).borderRadius(12).backgroundColor(SURFACE)

        Column({ space: 8 }) {
          Text('设备令牌').fontFamily(APP_FONT).fontSize(16).fontColor(FOREGROUND)
          Text(this.tokenText).fontFamily(APP_FONT).fontSize(13).fontColor(MUTED)
          Button(this.hasToken ? '保存令牌到文件' : '获取令牌', { type: ButtonType.Normal })
            .fontFamily(APP_FONT).fontSize(14).fontColor(BACKGROUND).backgroundColor(ACCENT)
            .borderRadius(8).height(42).enabled(!this.busy).onClick(() => {
              if (this.hasToken) {
                this.saveToken();
              } else {
                this.obtainToken();
              }
            })
        }.width('100%').alignItems(HorizontalAlign.Start).padding(14).borderRadius(12).backgroundColor(SURFACE)
      }.width('100%').constraintSize({ maxWidth: 540 }).padding(20)
    }.width('100%').height('100%').align(Alignment.Top).backgroundColor(BACKGROUND)
  }
}
