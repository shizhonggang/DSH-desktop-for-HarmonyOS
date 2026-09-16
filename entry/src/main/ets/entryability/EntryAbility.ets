/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, ConfigurationConstant, UIAbility, Want, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { notificationManager } from '@kit.NotificationKit';
import { preferences } from '@kit.ArkData';

const DOMAIN = 0x0000;
// Align with the Electron shell: initial 1440x920 (see module.json5 metadata),
// minimum 960x640. The previous 1920x1280 was larger than the window itself.
const MIN_WINDOW_WIDTH_PX = 960;
const MIN_WINDOW_HEIGHT_PX = 640;

// Background notification (Tray equivalent) that reopens this singleton Ability.
const BUNDLE_NAME = 'com.example.dshdesktop';
const ABILITY_NAME = 'EntryAbility';
const NOTIFICATION_ID = 1001;

const PREF_NAME = 'dsh_desktop_settings';
const PREF_KEY_WINDOW_RECT = 'windowRect';
const PREF_KEY_COLOR_MODE = 'colorMode';
const COLOR_MODE_SYSTEM = 'system';
const COLOR_MODE_LIGHT = 'light';
const COLOR_MODE_DARK = 'dark';

export default class EntryAbility extends UIAbility {
  private mainWindow?: window.Window;
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const colorMode = this.loadColorMode();
    this.applyColorMode(colorMode);
    AppStorage.setOrCreate<string>('dshColorMode', colorMode);
    // dsh web launches with a random per-process token; the WebView must visit
    // `/?token=…` once so dsh web sets an auth cookie (its signing secret is
    // persisted), after which token-free loads work for the cookie lifetime.
    // The launch helper (launch-local.sh) parses the token from `dsh web` stdout
    // and passes it here as `dsh_token`.
    let token = '';
    const params: Record<string, Object> = want.parameters ?? {};
    const raw = params['dsh_token'];
    if (typeof raw === 'string' && raw.trim().length > 0) {
      token = raw.trim();
      AppStorage.setOrCreate<string>('dshToken', token);
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  private loadColorMode(): string {
    try {
      const pref = preferences.getPreferencesSync(this.context, { name: PREF_NAME });
      return pref.getSync(PREF_KEY_COLOR_MODE, COLOR_MODE_SYSTEM) as string;
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to load color mode. Cause: %{public}s', JSON.stringify(err));
      return COLOR_MODE_SYSTEM;
    }
  }

  private applyColorMode(mode: string): void {
    let target: ConfigurationConstant.ColorMode;
    if (mode === COLOR_MODE_LIGHT) {
      target = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (mode === COLOR_MODE_DARK) {
      target = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } else {
      target = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    }
    try {
      this.context.getApplicationContext().setColorMode(target);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');

      const mainWindow: window.Window = windowStage.getMainWindowSync();
      if (mainWindow === undefined) {
        hilog.error(DOMAIN, 'testTag', 'Main window is undefined');
        return;
      }
      this.mainWindow = mainWindow;

      // Restore previous window position/size.
      this.restoreWindowRect(mainWindow);

      // Hide the system title bar (frameless, like Electron's hidden title bar).
      try {
        mainWindow.setWindowDecorVisible(false);
      } catch (err) {
        hilog.error(DOMAIN, 'testTag', 'Failed to hide title bar. Cause: %{public}s', JSON.stringify(err));
      }

      // Hide native title-bar buttons; the app draws its own macOS-style
      // traffic lights in the top-left corner.
      try {
        mainWindow.setWindowTitleButtonVisible(false, false, false);
      } catch (err) {
        hilog.error(DOMAIN, 'testTag', 'Failed to hide title buttons. Cause: %{public}s', JSON.stringify(err));
      }

      try {
        const limits: window.WindowLimits = {
          minWidth: MIN_WINDOW_WIDTH_PX,
          minHeight: MIN_WINDOW_HEIGHT_PX
        };
        mainWindow.setWindowLimits(limits).then((data: window.WindowLimits) => {
          hilog.info(DOMAIN, 'testTag', 'Succeeded in setting window limits. Cause: %{public}s', JSON.stringify(data));
        }).catch((limitErr: BusinessError) => {
          hilog.error(DOMAIN, 'testTag', 'Failed to set window limits. Cause: %{public}s', JSON.stringify(limitErr));
        });
      } catch (exception) {
        hilog.error(DOMAIN, 'testTag', 'Failed to set window limits. Cause: %{public}s', JSON.stringify(exception));
      }

      // Allow the window to receive system drag events (e.g. files dragged in).
      // Whether the WebView turns these into HTML5 drop events depends on the
      // HarmonyOS PC build; this is the best we can do from the app side.
      try {
        mainWindow.setReceiveDragEventEnabled(true).then(() => {
          hilog.info(DOMAIN, 'testTag', 'Succeeded in enabling drag event receiving.');
        }).catch((dragErr: BusinessError) => {
          hilog.error(DOMAIN, 'testTag', 'Failed to enable drag event receiving. Cause: %{public}s', JSON.stringify(dragErr));
        });
      } catch (exception) {
        hilog.error(DOMAIN, 'testTag', 'Failed to enable drag event receiving. Cause: %{public}s', JSON.stringify(exception));
      }
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
    this.saveWindowRect();
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    this.cancelBackgroundNotification();
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    // Tray equivalent: publish a notification that reopens this Ability when the
    // window is closed/minimized. The Host (`dsh web`) lives system-side, so the
    // app itself only needs a way to be brought back to the foreground.
    this.publishBackgroundNotification();
  }

  private restoreWindowRect(mainWindow: window.Window): void {
    try {
      const pref = preferences.getPreferencesSync(this.context, { name: PREF_NAME });
      const saved = pref.getSync(PREF_KEY_WINDOW_RECT, '') as string;
      if (!saved) return;

      const rect: window.Rect = JSON.parse(saved);
      const left = Math.max(0, rect.left ?? 0);
      const top = Math.max(0, rect.top ?? 0);
      const width = Math.max(MIN_WINDOW_WIDTH_PX, rect.width ?? MIN_WINDOW_WIDTH_PX);
      const height = Math.max(MIN_WINDOW_HEIGHT_PX, rect.height ?? MIN_WINDOW_HEIGHT_PX);

      mainWindow.moveWindowTo(left, top).then(() => {
        return mainWindow.resize(width, height);
      }).then(() => {
        hilog.info(DOMAIN, 'testTag', 'Restored window rect: %{public}s', JSON.stringify({ left, top, width, height }));
      }).catch((moveErr: BusinessError) => {
        hilog.error(DOMAIN, 'testTag', 'Failed to restore window rect. Cause: %{public}s', JSON.stringify(moveErr));
      });
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to read window rect preference. Cause: %{public}s', JSON.stringify(err));
    }
  }

  private saveWindowRect(): void {
    if (!this.mainWindow) return;
    try {
      const props = this.mainWindow.getWindowProperties();
      const rect = props.windowRect;
      const pref = preferences.getPreferencesSync(this.context, { name: PREF_NAME });
      pref.putSync(PREF_KEY_WINDOW_RECT, JSON.stringify(rect));
      pref.flushSync();
      hilog.info(DOMAIN, 'testTag', 'Saved window rect: %{public}s', JSON.stringify(rect));
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to save window rect. Cause: %{public}s', JSON.stringify(err));
    }
  }

  private publishBackgroundNotification(): void {
    try {
      const want: Want = {
        bundleName: BUNDLE_NAME,
        abilityName: ABILITY_NAME
      };
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [want],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: NOTIFICATION_ID,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      wantAgent.getWantAgent(wantAgentInfo).then((agent: WantAgent) => {
        const request: notificationManager.NotificationRequest = {
          id: NOTIFICATION_ID,
          content: {
            notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
            normal: {
              title: 'DshDesktop',
              text: 'DeepSeek Harness is running in the background. Tap to reopen.'
            }
          },
          wantAgent: agent
        };
        return notificationManager.publish(request);
      }).catch((err: BusinessError) => {
        hilog.error(DOMAIN, 'testTag', 'Failed to publish background notification. Cause: %{public}s', JSON.stringify(err));
      });
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to build background notification. Cause: %{public}s', JSON.stringify(err));
    }
  }

  private cancelBackgroundNotification(): void {
    try {
      notificationManager.cancel(NOTIFICATION_ID).catch((err: BusinessError) => {
        hilog.error(DOMAIN, 'testTag', 'Failed to cancel background notification. Cause: %{public}s', JSON.stringify(err));
      });
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to cancel background notification. Cause: %{public}s', JSON.stringify(err));
    }
  }
}
