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
import { window, display } from '@kit.ArkUI';
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
  // dsh web launch token, passed from the launcher via EntryAbility
  // (`want.parameters.dsh_token`). Used once to obtain the auth cookie.
  @StorageLink('dshToken') dshToken: string = '';

  private readonly DSH_WEB_URL = 'http://127.0.0.1:3080/?dsh-desktop-platform=linux';
  private readonly PREF_NAME = 'dsh_desktop_settings';
  private readonly PREF_KEY_COLOR_MODE = 'colorMode';
  private readonly PREF_KEY_WINDOW_RECT = 'windowRect';
  private readonly COLOR_MODE_SYSTEM = 'system';
  private readonly COLOR_MODE_LIGHT = 'light';
  private readonly COLOR_MODE_DARK = 'dark';

  // If the launcher gave us this run's dsh web token, append it so the first
  // load performs the one-time auth handshake (dsh web replies 303 with an auth
  // cookie for this origin). After that, token-free loads work via the cookie.
  private resolvedWebUrl(): string {
    const t = this.dshToken.trim();
    if (t.length === 0) {
      return this.DSH_WEB_URL;
    }
    // dsh web launch tokens are base64url (A-Za-z0-9_-), safe to append raw.
    const sep = this.DSH_WEB_URL.includes('?') ? '&' : '?';
    return this.DSH_WEB_URL + sep + 'token=' + t;
  }

  // Title-bar drag state.
  private cachedWindow?: window.Window;
  private dragStartX = 0;
  private dragStartY = 0;
  private winStartLeft = 0;
  private winStartTop = 0;
  private densityPixels = 1;

  aboutToAppear(): void {
    this.checkServer();
    // Cache the window for title-bar dragging.
    this.getMainWindow().then((win) => {
      this.cachedWindow = win;
    });
    try {
      this.densityPixels = display.getDefaultDisplaySync().densityPixels;
    } catch (err) {
      console.error('Failed to read display density:', err);
    }
  }

  private checkServer(): void {
    this.isChecking = true;
    this.isServerReady = false;
    const httpRequest = http.createHttp();
    httpRequest.request(
      this.resolvedWebUrl(),
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

  private async isWindowMaximized(): Promise<boolean> {
    const win = this.cachedWindow ?? await this.getMainWindow();
    if (!win) return false;
    try {
      const props = win.getWindowProperties();
      // When windowRect equals the full screen work area, treat as maximized.
      // This is a heuristic; HarmonyOS does not expose a direct isMaximized API.
      return false;
    } catch (err) {
      return false;
    }
  }

  private async toggleMaximize(): Promise<void> {
    const win = this.cachedWindow ?? await this.getMainWindow();
    if (!win) return;
    try {
      // HarmonyOS does not provide a direct maximize/restore API.
      // We use full-screen as the closest equivalent, and restore to the saved rect.
      const props = win.getWindowProperties();
      const isFullScreen = props.windowRect.width >= display.getDefaultDisplaySync().width &&
                           props.windowRect.height >= display.getDefaultDisplaySync().height;
      if (isFullScreen) {
        this.restoreWindowRect(win);
      } else {
        this.saveWindowRectForRestore(win);
        win.setFullScreen(true).catch((err: Error) => {
          console.error('Failed to set full screen:', err);
        });
      }
    } catch (err) {
      console.error('Failed to toggle maximize:', err);
    }
  }

  private saveWindowRectForRestore(mainWindow: window.Window): void {
    try {
      const props = mainWindow.getWindowProperties();
      const rect = props.windowRect;
      const pref = preferences.getPreferencesSync(getContext(this), { name: this.PREF_NAME });
      pref.putSync(this.PREF_KEY_WINDOW_RECT, JSON.stringify(rect));
      pref.flushSync();
    } catch (err) {
      console.error('Failed to save window rect for restore:', err);
    }
  }

  private restoreWindowRect(mainWindow: window.Window): void {
    try {
      const pref = preferences.getPreferencesSync(getContext(this), { name: this.PREF_NAME });
      const saved = pref.getSync(this.PREF_KEY_WINDOW_RECT, '') as string;
      if (!saved) {
        mainWindow.setFullScreen(false).catch((err: Error) => {
          console.error('Failed to exit full screen:', err);
        });
        return;
      }
      const rect: window.Rect = JSON.parse(saved);
      mainWindow.setFullScreen(false).then(() => {
        return mainWindow.moveWindowTo(Math.max(0, rect.left ?? 0), Math.max(0, rect.top ?? 0));
      }).then(() => {
        return mainWindow.resize(rect.width ?? 1440, rect.height ?? 920);
      }).catch((err: Error) => {
        console.error('Failed to restore window rect:', err);
      });
    } catch (err) {
      console.error('Failed to read window rect preference:', err);
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

  // Inject a context-aware right-click menu for the web content.
  // It offers copy/cut/paste/select-all when appropriate, and always keeps the
  // app-level items (refresh, minimize, color mode, close).
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
            max-width: 240px;
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
          .dsh-ctx-menu-separator {
            height: 1px;
            margin: 4px 8px;
            background: var(--dsw-alias-border-l2, #e0e0e0);
          }
          .dsh-ctx-menu-disabled {
            opacity: 0.4;
            pointer-events: none;
          }
        \`;
        document.head.appendChild(style);

        let menu = null;
        function showMenu(x, y, items) {
          if (menu) menu.remove();
          menu = document.createElement('div');
          menu.className = 'dsh-ctx-menu';
          menu.style.left = x + 'px';
          menu.style.top = y + 'px';

          let lastWasSeparator = false;
          items.forEach(item => {
            if (item.separator) {
              if (!lastWasSeparator) {
                const sep = document.createElement('div');
                sep.className = 'dsh-ctx-menu-separator';
                menu.appendChild(sep);
                lastWasSeparator = true;
              }
              return;
            }
            lastWasSeparator = false;
            const div = document.createElement('div');
            div.className = 'dsh-ctx-menu-item' + (item.disabled ? ' dsh-ctx-menu-disabled' : '');
            div.textContent = item.label;
            if (!item.disabled) {
              div.addEventListener('click', () => {
                item.action();
                hideMenu();
              });
            }
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

        function getSelectedText() {
          const sel = window.getSelection();
          return sel ? sel.toString().trim() : '';
        }

        function isEditable(el) {
          if (!el) return false;
          return el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable;
        }

        document.addEventListener('contextmenu', (e) => {
          const target = e.target;
          const link = target && (target.closest ? target.closest('a[href]') : null);
          const selected = getSelectedText();
          const editable = isEditable(target);

          const items = [];

          // Link-specific item
          if (link) {
            items.push({ label: '打开链接', action: () => { window.open(link.href, '_blank'); } });
            items.push({ label: '复制链接地址', action: () => { navigator.clipboard.writeText(link.href); } });
            items.push({ separator: true });
          }

          // Editable inputs: cut / copy / paste / select all
          if (editable) {
            items.push({ label: '剪切', action: () => document.execCommand('cut') });
            items.push({ label: '复制', action: () => document.execCommand('copy') });
            items.push({ label: '粘贴', action: () => document.execCommand('paste') });
            items.push({ label: '全选', action: () => document.execCommand('selectAll') });
            items.push({ separator: true });
          } else if (selected) {
            // Non-editable with selection: offer copy
            items.push({ label: '复制', action: () => document.execCommand('copy') });
            items.push({ separator: true });
          }

          // App-level items
          items.push({ label: '刷新', action: () => location.reload() });
          items.push({ label: '最小化', action: () => window.dshNative && window.dshNative.hide() });
          items.push({ label: '切换深浅色', action: () => window.dshNative && window.dshNative.toggleColorMode() });
          items.push({ label: '关闭', action: () => window.dshNative && window.dshNative.close() });

          e.preventDefault();
          showMenu(e.clientX, e.clientY, items);
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

  // System-level context menu shown when right-clicking the custom title bar.
  @Builder
  TitleBarContextMenu() {
    Menu() {
      MenuItem({ content: '刷新' })
        .onClick(() => {
          this.webController.refresh();
        })
      MenuItem({ content: '最小化' })
        .onClick(() => {
          this.nativeBridge.hide();
        })
      MenuItem({ content: '最大化 / 还原' })
        .onClick(() => {
          this.toggleMaximize();
        })
      MenuItem({ content: '切换深浅色' })
        .onClick(() => {
          this.toggleColorMode();
        })
      MenuItem({ content: '关闭' })
        .onClick(() => {
          this.nativeBridge.close();
        })
    }
  }

  // Invisible top drag hot zone. The system window controls (close/minimize/maximize)
  // live in the top-right corner, so the right 200vp is left non-draggable. The rest
  // of the strip can be dragged to move the window, double-clicked to maximize/restore,
  // and right-clicked for the system context menu.
  @Builder
  InvisibleDragZone() {
    Row()
      .width('100%')
      .height(40)
      .padding({ left: 16, right: 200 })
      .backgroundColor('rgba(0,0,0,0)')
      .bindContextMenu(this.TitleBarContextMenu(), ResponseType.RightClick)
      .onTouch((event: TouchEvent) => {
        const win = this.cachedWindow;
        if (!win || event.touches.length === 0) return;
        if (event.type === TouchType.Down) {
          const p = win.getWindowProperties();
          this.winStartLeft = p.windowRect.left;
          this.winStartTop = p.windowRect.top;
          this.dragStartX = event.touches[0].x;
          this.dragStartY = event.touches[0].y;
        } else if (event.type === TouchType.Move) {
          const dx = (event.touches[0].x - this.dragStartX) * this.densityPixels;
          const dy = (event.touches[0].y - this.dragStartY) * this.densityPixels;
          win.moveWindowTo(this.winStartLeft + Math.round(dx), this.winStartTop + Math.round(dy));
        }
      })
      .onClick((event: ClickEvent) => {
        if (event.timestamp - this.lastClickTime < 300) {
          this.toggleMaximize();
        }
        this.lastClickTime = event.timestamp;
      })
  }

  private lastClickTime = 0;

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
    // The Electron shell appends `dsh-desktop-platform=<process.platform>` so the
    // web app applies its desktop presentation marker. OpenHarmony reports
    // process.platform === 'openharmony', which the web app does not recognize yet;
    // we use the closest Linux profile so the desktop chrome/tray hints render.
    Web({ src: this.resolvedWebUrl(), controller: this.webController })
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

  @Builder
  Content() {
    if (this.isChecking) {
      this.LoadingBuilder()
    } else if (!this.isServerReady) {
      this.ErrorBuilder()
    } else {
      this.WebBuilder()
    }
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      this.Content()
      this.InvisibleDragZone()
    }
    .width('100%')
    .height('100%')
  }
}
