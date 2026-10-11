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

import { FormExtensionAbility, formBindingData, formInfo, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';

const DOMAIN = 0x0000;
const TAG = 'DshFormAbility';
const FORM_IDS_PREF = 'dsh_form_ids';
const FORM_IDS_KEY = 'formIds';

/**
 * Service card (服务卡片) lifecycle handler.
 *
 * The card shows DSH task status on the desktop / negative-one screen.
 * Data flows in through two paths:
 *   1. onAddForm — initial binding data when the user pins the card.
 *   2. updateCardData (static) — called by BridgeAgent when a task event
 *      arrives over the bridge so the card refreshes in place.
 *
 * The card UI lives in pages/DshCard.ets; this ability only manages the
 * form lifecycle and data channel.
 */
export default class DshFormAbility extends FormExtensionAbility {
  /**
   * 本应用已创建卡片的 formId 列表。
   *
   * 为什么要自己记：`getPublishedRunningFormInfos()` 是设备级枚举，三方调用报
   * 16500100；`getFormsInfo()` 返回的 FormInfo **没有 formId 字段**（formId 只在
   * RunningFormInfo 上，且本机运行时实测也不携带）。零权限且可靠的做法就是在
   * onAddForm 里把系统给的 formId 记下来（参数键 formInfo.FormParam.IDENTITY_KEY）。
   *
   * 2026-10-11 修正：纯内存静态表有个致命伤——FormExtensionAbility 跑在独立的
   * form 进程，且应用重启后表被清空而桌面卡片还在（updateCard 变成 cards:0）。
   * 现在双写：内存 + preferences（应用沙箱内跨进程共享，form 进程写、主进程读）。
   */
  private static formIds: string[] = [];

  static knownFormIds(): string[] {
    return DshFormAbility.formIds;
  }

  /** 主进程（BridgeAgent）启动时调用：从 preferences 恢复历史 formId。 */
  static restoreFormIds(context: Context): void {
    try {
      const pref = preferences.getPreferencesSync(context, { name: FORM_IDS_PREF });
      const saved = pref.getSync(FORM_IDS_KEY, '[]') as string;
      const arr: string[] = JSON.parse(saved);
      for (const id of arr) {
        if (typeof id === 'string' && id.length > 0 && DshFormAbility.formIds.indexOf(id) < 0) {
          DshFormAbility.formIds.push(id);
        }
      }
      hilog.info(DOMAIN, TAG, 'restored %{public}d formIds from preferences', arr.length);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'restoreFormIds failed: %{public}s', JSON.stringify(err));
    }
  }

  private static persistFormIds(context: Context): void {
    try {
      const pref = preferences.getPreferencesSync(context, { name: FORM_IDS_PREF });
      pref.putSync(FORM_IDS_KEY, JSON.stringify(DshFormAbility.formIds));
      pref.flushSync();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'persistFormIds failed: %{public}s', JSON.stringify(err));
    }
  }

  private static rememberFormId(formId: string): void {
    if (formId.length === 0) {
      return;
    }
    if (DshFormAbility.formIds.indexOf(formId) < 0) {
      DshFormAbility.formIds.push(formId);
    }
  }

  onAddForm(want: Want): formBindingData.FormBindingData {
    hilog.info(DOMAIN, TAG, 'onAddForm called');
    try {
      const params = want.parameters;
      if (params !== undefined) {
        const id = params[formInfo.FormParam.IDENTITY_KEY];
        if (typeof id === 'string') {
          DshFormAbility.rememberFormId(id as string);
          DshFormAbility.persistFormIds(this.context);
          hilog.info(DOMAIN, TAG, 'onAddForm tracked formId %{public}s', id as string);
        }
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'onAddForm track failed: %{public}s', JSON.stringify(err));
    }
    // Default card data — will be overwritten by the first updateCardData call.
    const data = new Map<string, Object>();
    // Single-task fields (mini/wide cards)
    data.set('taskStatus', 'idle');
    data.set('taskTitle', 'DSH');
    data.set('taskDetail', 'No active task');
    data.set('updatedAt', '');
    data.set('runningCount', 0);
    // Multi-task fields (large card)
    data.set('tasks', '[]');
    data.set('rounds', 0);
    data.set('steps', 0);
    data.set('tokRate', '');
    data.set('tokTotal', '');
    data.set('cacheRate', '');
    data.set('progress', 0);
    return formBindingData.createFormBindingData(data);
  }

  onCastToNormalForm(formId: string): void {
    hilog.info(DOMAIN, TAG, 'onCastToNormalForm: %{public}s', formId);
  }

  onUpdateForm(formId: string): void {
    hilog.info(DOMAIN, TAG, 'onUpdateForm: %{public}s', formId);
  }

  onFormEvent(formId: string, message: string): void {
    hilog.info(DOMAIN, TAG, 'onFormEvent: %{public}s, message: %{public}s', formId, message);
    // Handle card interaction events (e.g. user tapped an action button).
    try {
      const event: Record<string, Object> = JSON.parse(message);
      const action = event['action'] as string;
      if (action === 'refresh') {
        // The card asked for a refresh — trigger a data update.
        const refreshData = new Map<string, Object>();
        refreshData.set('taskStatus', 'refreshing');
        refreshData.set('taskDetail', 'Refreshing…');
        DshFormAbility.updateCardData(this.context, formId, refreshData);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'onFormEvent parse failed: %{public}s', JSON.stringify(err));
    }
  }

  onRemoveForm(formId: string): void {
    hilog.info(DOMAIN, TAG, 'onRemoveForm: %{public}s', formId);
    const idx = DshFormAbility.formIds.indexOf(formId);
    if (idx >= 0) {
      DshFormAbility.formIds.splice(idx, 1);
      DshFormAbility.persistFormIds(this.context);
    }
  }

  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }

  /**
   * Push new data to every active card instance (or a specific one).
   * Called from BridgeAgent when the dsh bridge reports a task event.
   */
  static updateCardData(context: Context, formId: string, data: Map<string, Object>): void {
    try {
      const record: Record<string, Object> = {};
      data.forEach((value: Object, key: string) => {
        record[key] = value;
      });
      const binding = formBindingData.createFormBindingData(record);
      formProvider.updateForm(formId, binding).then(() => {
        hilog.info(DOMAIN, TAG, 'Card %{public}s updated', formId);
      }).catch((err: Error) => {
        hilog.error(DOMAIN, TAG, 'updateForm failed: %{public}s', JSON.stringify(err));
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'updateCardData failed: %{public}s', JSON.stringify(err));
    }
  }
}
