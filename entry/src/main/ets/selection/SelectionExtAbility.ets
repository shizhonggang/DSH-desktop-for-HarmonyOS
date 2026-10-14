/*
 * 划词扩展能力（SelectionExtensionAbility）—— DSH 划词助手
 *
 * 用户在任意应用里双击/三击/拖动选中文本后，系统把本扩展拉起并回调
 * selectionCompleted；我们取到选中文本后：
 *   ① POST 到 node 侧桥（/event，event=selectionAsk）→ 任何 DSH 会话都能读到；
 *   ② 在鼠标划词起点弹出一个小面板（pages/SelectionPanel），提供 复制 / 问 DSH / 关闭。
 *
 * 前置（用户侧，一次性）：设置 → 系统 → 智慧划词 → 打开开关，并把"划词应用"选成 DshDesktop。
 * 平台约束：仅 PC/2in1；API 24+；零权限。
 */

import { selectionManager, SelectionExtensionAbility, PanelInfo, PanelType } from '@kit.BasicServicesKit';
import { rpc } from '@kit.IPCKit';
import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { http } from '@kit.NetworkKit';
import { SelectionStore } from './SelectionStore';

const DOMAIN = 0x0000;
const TAG = 'DshSelection';
const BRIDGE_EVENT_URL = 'http://127.0.0.1:3131/event';

/** onConnect 必须返回一个 rpc.RemoteObject 桩对象。 */
class SelectionStub extends rpc.RemoteObject {
  constructor(des: string) {
    super(des);
  }

  onRemoteMessageRequest(code: number, data: rpc.MessageSequence, reply: rpc.MessageSequence,
    options: rpc.MessageOption): boolean | Promise<boolean> {
    return true;
  }
}

export default class SelectionExtAbility extends SelectionExtensionAbility {
  private panel: selectionManager.Panel | undefined = undefined;

  onConnect(want: Want): rpc.RemoteObject {
    hilog.info(DOMAIN, TAG, 'onConnect');
    try {
      selectionManager.on('selectionCompleted', (info: selectionManager.SelectionInfo) => {
        this.onSelected(info);
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'on(selectionCompleted) failed: %{public}s', this.text(err));
    }
    return new SelectionStub('dsh-selection');
  }

  onDisconnect(): void {
    hilog.info(DOMAIN, TAG, 'onDisconnect');
    try {
      selectionManager.off('selectionCompleted');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'off failed: %{public}s', this.text(err));
    }
    if (this.panel !== undefined) {
      try {
        selectionManager.destroyPanel(this.panel);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'destroyPanel failed: %{public}s', this.text(err));
      }
      this.panel = undefined;
    }
  }

  private async onSelected(info: selectionManager.SelectionInfo): Promise<void> {
    let content = '';
    try {
      content = await selectionManager.getSelectionContent();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'getSelectionContent failed: %{public}s', this.text(err));
      return;
    }
    if (content.length === 0) {
      return;
    }
    const store = SelectionStore.get();
    store.text = content;
    store.sourceBundle = info.bundleName;
    this.postEvent(content, info.bundleName);

    await this.ensurePanel();
    const panel = this.panel;
    if (panel === undefined) {
      return;
    }
    try {
      await panel.moveToGlobalDisplay(info.startDisplayX, info.startDisplayY + 28);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'move failed: %{public}s', this.text(err));
    }
    try {
      await panel.show();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'show failed: %{public}s', this.text(err));
    }
  }

  /** 面板懒创建（一次创建、复用；避免首次划词延迟）。 */
  private async ensurePanel(): Promise<void> {
    if (this.panel !== undefined) {
      return;
    }
    const info: PanelInfo = {
      panelType: PanelType.MENU_PANEL,
      x: 0,
      y: 0,
      width: 380,
      height: 132
    };
    try {
      const panel: selectionManager.Panel = await selectionManager.createPanel(this.context, info);
      this.panel = panel;
      SelectionStore.get().panel = panel;
      try {
        panel.on('hidden', () => {
          hilog.info(DOMAIN, TAG, 'panel hidden');
        });
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'on(hidden) failed: %{public}s', this.text(err));
      }
      await panel.setUiContent('pages/SelectionPanel');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'createPanel failed: %{public}s', this.text(err));
      this.panel = undefined;
    }
  }

  /** 把划词内容投给 node 侧（桥的 /event → /ui-events，任何 DSH 会话可读）。 */
  private postEvent(text: string, bundle: string): void {
    const request = http.createHttp();
    const payload = '{"event":"selectionAsk","data":{"text":"' + this.jsonEscape(text) +
      '","from":"' + this.jsonEscape(bundle) + '"}}';
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: { 'Content-Type': 'application/json' },
      extraData: payload,
      connectTimeout: 2000,
      readTimeout: 3000
    };
    request.request(BRIDGE_EVENT_URL, options).then(() => {
      request.destroy();
    }).catch((err: Object) => {
      hilog.warn(DOMAIN, TAG, 'postEvent failed: %{public}s', this.text(err));
      request.destroy();
    });
  }

  /** 最小 JSON 字符串转义（ArkTS 禁未声明类型的对象字面量，所以手拼）。 */
  private jsonEscape(value: string): string {
    return value.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n').replace(/\r/g, '\\r');
  }

  private text(value: Object): string {
    if (value instanceof Error) {
      return (value as Error).message;
    }
    return typeof value === 'string' ? value as string : JSON.stringify(value);
  }
}
