/*
 * 划词助手：跨文件共享的选中文本 / 面板句柄。
 *
 * 划词扩展能力（SelectionExtensionAbility）与划词面板页面（pages/SelectionPanel）
 * 跑在同一个进程里，但它们是两个模块，用这个单例传递数据。
 */

import { selectionManager } from '@kit.BasicServicesKit';

export class SelectionStore {
  private static instance: SelectionStore | undefined = undefined;

  /** 最近一次划词的文本。 */
  text: string = '';
  /** 划词发生的应用（SelectionInfo.bundleName）。 */
  sourceBundle: string = '';
  /** 面板句柄，供页面里的"关闭"按钮使用。 */
  panel: selectionManager.Panel | undefined = undefined;

  static get(): SelectionStore {
    if (SelectionStore.instance === undefined) {
      SelectionStore.instance = new SelectionStore();
    }
    return SelectionStore.instance;
  }
}
