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

import { webview } from '@kit.ArkWeb';
import { http } from '@kit.NetworkKit';
import { window } from '@kit.ArkUI';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

// JS Bridge interface exposed to the dsh web frontend.
interface DshNativeBridge {
  minimize: () => Promise<void>;
  hide: () => Promise<void>;
  close: () => Promise<void>;
  zoomIn: () => Promise<void>;
  zoomOut: () => Promise<void>;
  resetZoom: () => Promise<void>;
  toggleColorMode: () => Promise<void>;
}

@Entry
@Component
struct Index {
  webController: webview.WebviewController = new webview.WebviewController();

  @State isServerReady: boolean = false;
  @State isChecking: boolean = true;
  @StorageLink('dshColorMode') colorMode: string = 'system';

  private readonly DSH_WEB_URL = 'http://127.0.0.1:3080/?dsh-desktop-platform=linux';
  private readonly PREF_NAME = 'dsh_desktop_settings';
  private readonly PREF_KEY_COLOR_MODE = 'colorMode';
  private readonly COLOR_MODE_SYSTEM = 'system';
  private readonly COLOR_MODE_LIGHT = 'light';
  private readonly COLOR_MODE_DARK = 'dark';

  aboutToAppear(): void {
    this.checkServer();
  }

  private checkServer(): void {
    this.isChecking = true;
    this.isServerReady = false;
    const httpRequest = http.createHttp();
    httpRequest.request(
      this.DSH_WEB_URL,
      {
        method: http.RequestMethod.GET,
        connectTimeout: 2000,
        readTimeout: 2000
      },
      (err, data) => {
        this.isChecking = false;
        if (!err && data && data.responseCode >= 200 && data.responseCode < 400) {
          this.isServerReady = true;
        } else {
          this.isServerReady = false;
          if (err) {
            console.error('dsh web health check failed:', JSON.stringify(err));
          }
        }
        httpRequest.destroy();
      }
    );
  }

  private getWebDarkMode(): WebDarkMode {
    if (this.colorMode === this.COLOR_MODE_LIGHT) {
      return WebDarkMode.Off;
    } else if (this.colorMode === this.COLOR_MODE_DARK) {
      return WebDarkMode.On;
    }
    return WebDarkMode.Auto;
  }

  private saveColorMode(mode: string): void {
    try {
      const pref = preferences.getPreferencesSync(getContext(this), { name: this.PREF_NAME });
      pref.putSync(this.PREF_KEY_COLOR_MODE, mode);
      pref.flushSync();
    } catch (err) {
      console.error('Failed to save color mode:', err);
    }
  }

  private applyAppColorMode(mode: string): void {
    let target: ConfigurationConstant.ColorMode;
    if (mode === this.COLOR_MODE_LIGHT) {
      target = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (mode === this.COLOR_MODE_DARK) {
      target = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } else {
      target = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    }
    try {
      (getContext(this) as common.UIAbilityContext).getApplicationContext().setColorMode(target);
    } catch (err) {
      console.error('Failed to apply app color mode:', err);
    }
  }

  private toggleColorMode(): void {
    const modes: string[] = [this.COLOR_MODE_SYSTEM, this.COLOR_MODE_LIGHT, this.COLOR_MODE_DARK];
    const idx = modes.indexOf(this.colorMode);
    const next = modes[(idx + 1) % modes.length];
    this.colorMode = next;
    this.saveColorMode(next);
    this.applyAppColorMode(next);
  }

  // JS Bridge: expose native window operations to the dsh web frontend so it can
  // trigger minimize/hide/close just like the Electron shell does.
  private async getMainWindow(): Promise<window.Window | undefined> {
    try {
      return await window.getLastWindow(getContext(this));
    } catch (err) {
      console.error('Failed to get main window:', err);
      return undefined;
    }
  }

  private nativeBridge: DshNativeBridge = {
    minimize: async (): Promise<void> => {
      try {
        const win = await this.getMainWindow();
        await win?.minimize();
      } catch (err) {
        console.error('Failed to minimize window:', err);
      }
    },
    hide: async (): Promise<void> => {
      // HarmonyOS Window has no hide() API; minimize is the closest equivalent.
      try {
        const win = await this.getMainWindow();
        await win?.minimize();
      } catch (err) {
        console.error('Failed to hide window:', err);
      }
    },
    close: async (): Promise<void> => {
      try {
        (getContext(this) as common.UIAbilityContext).terminateSelf();
      } catch (err) {
        console.error('Failed to close window:', err);
      }
    },
    zoomIn: async (): Promise<void> => {
      try {
        this.webController.zoomIn();
      } catch (err) {
        console.error('Failed to zoom in:', err);
      }
    },
    zoomOut: async (): Promise<void> => {
      try {
        this.webController.zoomOut();
      } catch (err) {
        console.error('Failed to zoom out:', err);
      }
    },
    resetZoom: async (): Promise<void> => {
      try {
        this.webController.zoom(1.0);
      } catch (err) {
        console.error('Failed to reset zoom:', err);
      }
    },
    toggleColorMode: async (): Promise<void> => {
      this.toggleColorMode();
    }
  };

  // Hide only the dsh web's session log button to avoid overlapping HarmonyOS
  // system window controls in the top-right corner. The class hash changes per
  // build, but the "_sessionLogButton" suffix is stable.
  private hideSessionLogButton(): void {
    const css = '[class*="_sessionLogButton"] { display: none !important; }';
    this.webController.runJavaScript(`
      (function() {
        const id = 'dsh-harmonyos-hide-sessionlog';
        if (document.getElementById(id)) return;
        const style = document.createElement('style');
        style.id = id;
        style.textContent = ${JSON.stringify(css)};
        document.head.appendChild(style);
      })();
    `).catch((err: Error) => {
      console.error('Failed to hide session log button:', err);
    });
  }

  // Inject desktop-style keyboard shortcuts into the web page.
  private injectKeyboardShortcuts(): void {
    const script = `
      (function() {
        const id = 'dsh-harmonyos-keyboard';
        if (document.getElementById(id)) return;
        document.head.appendChild((() => { const s = document.createElement('style'); s.id = id; return s; })());

        document.addEventListener('keydown', (e) => {
          const mod = e.ctrlKey || e.metaKey;
          if (!mod) return;

          const key = e.key.toLowerCase();
          if (e.shiftKey && key === 'l') {
            e.preventDefault();
            if (window.dshNative) window.dshNative.toggleColorMode();
          } else if (key === 'w') {
            e.preventDefault();
            if (window.dshNative) window.dshNative.hide();
          } else if (key === 'r') {
            e.preventDefault();
            location.reload();
          } else if (key === '+' || key === '=') {
            e.preventDefault();
            if (window.dshNative) window.dshNative.zoomIn();
          } else if (key === '-') {
            e.preventDefault();
            if (window.dshNative) window.dshNative.zoomOut();
          } else if (key === '0') {
            e.preventDefault();
            if (window.dshNative) window.dshNative.resetZoom();
          }
        });
      })();
    `;
    this.webController.runJavaScript(script).catch((err: Error) => {
      console.error('Failed to inject keyboard shortcuts:', err);
    });
  }

  // Inject a simple right-click context menu for desktop-like operations.
  private injectContextMenu(): void {
    const script = `
      (function() {
        const id = 'dsh-harmonyos-contextmenu';
        if (document.getElementById(id)) return;

        const style = document.createElement('style');
        style.id = id;
        style.textContent = \`
          .dsh-ctx-menu {
            position: fixed;
            z-index: 999999;
            min-width: 140px;
            background: var(--dsw-alias-bg-base, #fff);
            border: 1px solid var(--dsw-alias-border-l2, #e0e0e0);
            border-radius: 8px;
            box-shadow: 0 4px 12px rgba(0,0,0,0.15);
            padding: 4px 0;
            font-family: var(--dsw-font-family, system-ui, -apple-system, sans-serif);
            font-size: 13px;
            color: var(--dsw-alias-label-primary, #000);
          }
          .dsh-ctx-menu-item {
            padding: 8px 16px;
            cursor: pointer;
            white-space: nowrap;
          }
          .dsh-ctx-menu-item:hover {
            background: var(--dsw-alias-interactive-bg-hover, #f5f5f5);
          }
        \`;
        document.head.appendChild(style);

        let menu = null;
        function showMenu(x, y) {
          if (menu) menu.remove();
          menu = document.createElement('div');
          menu.className = 'dsh-ctx-menu';
          menu.style.left = x + 'px';
          menu.style.top = y + 'px';

          const items = [
            { label: '刷新', action: () => location.reload() },
            { label: '最小化', action: () => window.dshNative && window.dshNative.hide() },
            { label: '切换深浅色', action: () => window.dshNative && window.dshNative.toggleColorMode() },
            { label: '关闭', action: () => window.dshNative && window.dshNative.close() }
          ];

          items.forEach(item => {
            const div = document.createElement('div');
            div.className = 'dsh-ctx-menu-item';
            div.textContent = item.label;
            div.addEventListener('click', () => {
              item.action();
              menu.remove();
              menu = null;
            });
            menu.appendChild(div);
          });

          document.body.appendChild(menu);
        }

        function hideMenu() {
          if (menu) {
            menu.remove();
            menu = null;
          }
        }

        document.addEventListener('contextmenu', (e) => {
          // Do not override context menus inside text/code inputs or links.
          const target = e.target;
          if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.tagName === 'A' || target.closest('a'))) {
            return;
          }
          e.preventDefault();
          showMenu(e.clientX, e.clientY);
        });

        document.addEventListener('click', (e) => {
          if (menu && !menu.contains(e.target)) hideMenu();
        });
        document.addEventListener('scroll', hideMenu, true);
      })();
    `;
    this.webController.runJavaScript(script).catch((err: Error) => {
      console.error('Failed to inject context menu:', err);
    });
  }

  @Builder
  LoadingBuilder() {
    Column() {
      LoadingProgress()
        .width(48)
        .height(48)
        .color($r('sys.color.font_primary'))
      Text('正在连接 DeepSeek Harness...')
        .fontSize(16)
        .fontColor($r('sys.color.font_primary'))
        .margin({ top: 16 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('sys.color.background_primary'))
  }

  @Builder
  ErrorBuilder() {
    Column() {
      Text('无法连接到 dsh web')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
      Text('请先在终端启动服务端：')
        .fontSize(14)
        .fontColor($r('sys.color.font_secondary'))
        .margin({ top: 12 })
      Text('dsh web --host 127.0.0.1 --port 3080')
        .fontSize(14)
        .fontColor($r('sys.color.font_secondary'))
        .fontFamily('monospace')
        .margin({ top: 4 })
      Button('重试')
        .type(ButtonType.Capsule)
        .margin({ top: 32 })
        .onClick(() => this.checkServer())
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(24)
    .backgroundColor($r('sys.color.background_primary'))
  }

  @Builder
  WebBuilder() {
    Column() {
      // The Electron shell appends `dsh-desktop-platform=<process.platform>` so the
      // web app applies its desktop presentation marker. OpenHarmony reports
      // process.platform === 'openharmony', which the web app does not recognize yet;
      // we use the closest Linux profile so the desktop chrome/tray hints render.
      Web({ src: this.DSH_WEB_URL, controller: this.webController })
        .width('100%')
        .height('100%')
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .onlineImageAccess(true)
        .mixedMode(MixedMode.All)
        .darkMode(this.getWebDarkMode())
        .zoomAccess(true)
        .javaScriptProxy({
          object: this.nativeBridge,
          name: 'dshNative',
          methodList: [],
          asyncMethodList: ['minimize', 'hide', 'close', 'zoomIn', 'zoomOut', 'resetZoom', 'toggleColorMode'],
          controller: this.webController
        })
        .onPageEnd((event) => {
          this.hideSessionLogButton();
          this.injectKeyboardShortcuts();
          this.injectContextMenu();
        })
    }
    .width('100%')
    .height('100%')
  }

  build() {
    if (this.isChecking) {
      this.LoadingBuilder()
    } else if (!this.isServerReady) {
      this.ErrorBuilder()
    } else {
      this.WebBuilder()
    }
  }
}
