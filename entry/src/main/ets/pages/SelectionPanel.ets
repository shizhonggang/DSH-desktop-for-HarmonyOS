/*
 * 划词助手面板（pages/SelectionPanel）
 *
 * 由 SelectionExtAbility 通过 selectionManager.Panel.setUiContent() 加载。
 * 三个动作：复制 / 问 DSH / 关闭。
 *   复制  → 写系统剪贴板（零权限）
 *   问 DSH → POST 到 node 侧桥 /event（event=selectionAsk），任何 DSH 会话可读
 *   关闭  → 隐藏面板
 */

import { selectionManager } from '@kit.BasicServicesKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SelectionStore } from '../selection/SelectionStore';

const DOMAIN = 0x0000;
const TAG = 'DshSelectionPanel';
const BRIDGE_EVENT_URL = 'http://127.0.0.1:3131/event';

@Entry
@Component
struct SelectionPanel {
  @State preview: string = '';
  @State tip: string = '';

  aboutToAppear(): void {
    const text = SelectionStore.get().text;
    this.preview = text.length > 80 ? text.substring(0, 80) + '…' : text;
  }

  private copyToClipboard(): void {
    const text = SelectionStore.get().text;
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.tip = '已复制';
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'copy failed: %{public}s', JSON.stringify(err));
      this.tip = '复制失败';
    }
  }

  private askDsh(): void {
    const store = SelectionStore.get();
    const request = http.createHttp();
    const payload = '{"event":"selectionAsk","data":{"text":"' + this.jsonEscape(store.text) +
      '","from":"' + this.jsonEscape(store.sourceBundle) + '"}}';
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: { 'Content-Type': 'application/json' },
      extraData: payload,
      connectTimeout: 2000,
      readTimeout: 3000
    };
    request.request(BRIDGE_EVENT_URL, options).then(() => {
      request.destroy();
      this.tip = '已发给 DSH';
    }).catch((err: Object) => {
      request.destroy();
      hilog.warn(DOMAIN, TAG, 'askDsh failed: %{public}s', JSON.stringify(err));
      this.tip = '发送失败';
    });
  }

  /** 最小 JSON 字符串转义（ArkTS 禁未声明类型的对象字面量）。 */
  private jsonEscape(value: string): string {
    return value.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n').replace(/\r/g, '\\r');
  }

  private hidePanel(): void {
    const panel: selectionManager.Panel | undefined = SelectionStore.get().panel;
    if (panel !== undefined) {
      panel.hide().catch((err: Object) => {
        hilog.warn(DOMAIN, TAG, 'hide failed: %{public}s', JSON.stringify(err));
      });
    }
  }

  build() {
    Column({ space: 8 }) {
      Text(this.preview.length > 0 ? this.preview : '（未取到选中文本）')
        .fontSize(13)
        .fontColor('#E6FFFFFF')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Row({ space: 8 }) {
        Button('复制')
          .fontSize(13)
          .height(30)
          .backgroundColor('#33FFFFFF')
          .onClick(() => this.copyToClipboard())
        Button('问 DSH')
          .fontSize(13)
          .height(30)
          .backgroundColor('#3D7EFF')
          .onClick(() => this.askDsh())
        Button('关闭')
          .fontSize(13)
          .height(30)
          .backgroundColor('#33FFFFFF')
          .onClick(() => this.hidePanel())
        if (this.tip.length > 0) {
          Text(this.tip).fontSize(12).fontColor('#9E9E9E')
        }
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor('#F21C1C1C')
    .borderRadius(12)
  }
}
