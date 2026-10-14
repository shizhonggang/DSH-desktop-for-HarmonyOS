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

/**
 * 运行时权限申请（user_grant 权限）。
 *
 * 背景：module.json5 里 `grantMode: user_grant` 的权限**光声明不会生效**，
 * 必须在运行时调用 requestPermissionsFromUser 弹窗，用户同意后才置为已授予。
 * `system_grant` 的权限（如 KEEP_BACKGROUND_RUNNING）安装即授予，无需在此列。
 *
 * 这里的清单分两组：USER_GRANT_PERMISSIONS = normal 级 + user_grant（不需要 ACL 审批）；
 * ACL_PERMISSIONS = profile ACL 背书 + user_grant（试用 profile 2026-10-16 到期）。
 * 两组都必须运行时弹窗：profile 只解锁"可授予"，不等于已授予。
 *
 * 见 skill: harmonyos-pc-control/reference/permission-tiers.md
 */

import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'DshPerm';

/** 需要运行时弹窗的权限（normal 级 + user_grant）。 */
const USER_GRANT_PERMISSIONS: Permissions[] = [
  // 日历读写：通过 DataShare(datashare://calendardata) 访问日程
  'ohos.permission.READ_CALENDAR',
  'ohos.permission.WRITE_CALENDAR',
  // 公共目录直读：免 hdc 文件搬运
  'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY',
  'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY',
  // 媒体与采集（按需才请求，这里一并列出，失败不影响其它）
  'ohos.permission.READ_MEDIA',
  'ohos.permission.WRITE_MEDIA',
  // 跨应用窗口列表 + 按窗截图（bridge listMainWindows/snapshotWindow 依赖）
  'ohos.permission.CUSTOM_SCREEN_CAPTURE',
  // 免打扰状态（决定是否打扰用户）
  'ohos.permission.GET_DONOTDISTURB_STATE',
  // 跨设备数据同步
  'ohos.permission.DISTRIBUTED_DATASYNC',
  // 蓝牙（外设管理）
  'ohos.permission.ACCESS_BLUETOOTH'
];

/**
 * ACL 权限（试用 profile 2026-10-16 到期，换装后即可运行时申请）。
 * 修正旧注释「ACL 权限不在此列」：profile ACL 只解锁"可授予"，授权仍要
 * requestPermissionsFromUser 弹窗（2026-10-11 实测 READ_PASTEBOARD 未请求则 -1）。
 * profile 不含某 ACL 时 request 会静默失败，不影响其它权限。
 */
const ACL_PERMISSIONS: Permissions[] = [
  // 剪贴板直读（应用内读系统剪贴板）
  'ohos.permission.READ_PASTEBOARD',
  // 识别前台/运行中应用与窗口归属
  'ohos.permission.GET_ABILITY_INFO',
  // 试用 ACL 五项（10-16 到期）
  'ohos.permission.INPUT_MONITORING',
  'ohos.permission.INTERCEPT_INPUT_EVENT',
  'ohos.permission.CUSTOM_SCREEN_RECORDING',
  'ohos.permission.CONTROL_DEVICE',
  'ohos.permission.MANAGE_RECENT_SNAPSHOT'
];

/** 单个权限的申请结果。 */
export interface PermissionOutcome {
  name: string;
  granted: boolean;
  code: number;
}

/**
 * 逐个申请 user_grant 权限。
 *
 * 逐个而不是一批的原因：一批里任一权限被拒会导致整批失败信息难定位；
 * 逐个申请便于把「哪个权限被拒了」如实回报。
 * 已授予的权限会跳过（不重复弹窗）。
 */
export class PermissionRequester {
  private context: common.UIAbilityContext;
  private results: Map<string, boolean> = new Map<string, boolean>();

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /** 返回上一次申请的结果快照（供 bridge 查询）。 */
  snapshot(): PermissionOutcome[] {
    const out: PermissionOutcome[] = [];
    this.results.forEach((granted: boolean, name: string) => {
      out.push({ name: name, granted: granted, code: granted ? 0 : -1 });
    });
    return out;
  }

  /**
   * 申请全部 user_grant 权限。
   * 返回实际被授予的清单；失败不抛出（逐个 catch，记录后继续）。
   */
  async requestAll(): Promise<PermissionOutcome[]> {
    const atManager = abilityAccessCtrl.createAtManager();
    const outcomes: PermissionOutcome[] = [];
    for (const permission of [...USER_GRANT_PERMISSIONS, ...ACL_PERMISSIONS]) {
      let granted = false;
      try {
        // 先查当前状态，已授予就跳过，避免重复弹窗打扰用户
        const status = await atManager.checkAccessToken(
          this.context.applicationInfo.accessTokenId, permission);
        if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          granted = true;
          hilog.info(DOMAIN, TAG, '%{public}s already granted', permission);
        } else {
          const result = await atManager.requestPermissionsFromUser(this.context, [permission]);
          const codes: number[] = result.authResults;
          granted = codes.length > 0 && codes[0] === 0;
          hilog.info(DOMAIN, TAG, 'request %{public}s -> %{public}d',
            permission, codes.length > 0 ? codes[0] : -999);
        }
      } catch (err) {
        hilog.error(DOMAIN, TAG, 'request %{public}s failed: %{public}s',
          permission, JSON.stringify(err));
      }
      this.results.set(permission, granted);
      outcomes.push({ name: permission, granted: granted, code: granted ? 0 : -1 });
    }
    return outcomes;
  }
}

/** 供参考：本模块覆盖的权限清单（bridge 可用它回报"该申请哪些"）。 */
export function userGrantPermissionList(): string[] {
  return USER_GRANT_PERMISSIONS.slice();
}
