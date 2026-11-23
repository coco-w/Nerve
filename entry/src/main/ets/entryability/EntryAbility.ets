import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { readPushLink } from '../push/PushLink';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  // 同步软键盘高度，供终端页面控制辅助按键栏的显示状态。
  private mainWindow: window.Window | undefined;
  private readonly updateKeyboardHeight = (height: number): void => {
    AppStorage.setOrCreate<number>('nerveKeyboardHeight', height);
  };

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.receivePushLink(want);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.receivePushLink(want);
  }

  private receivePushLink(want: Want): void {
    // 冷启动和热启动共用同一通知链接，普通启动不会清掉待处理通知。
    const link = readPushLink(want);
    if (link) AppStorage.setOrCreate<string>('nervePushLink', link);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });

    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      this.mainWindow = windowStage.getMainWindowSync();
      this.mainWindow.on('keyboardHeightChange', this.updateKeyboardHeight);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    try {
      this.mainWindow?.off('keyboardHeightChange', this.updateKeyboardHeight);
    } catch (_) {
      // 窗口可能已销毁，移除监听失败时仍继续清理页面状态。
    }
    this.mainWindow = undefined;
    this.updateKeyboardHeight(0);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
