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
 * Accessibility extension that gives dsh a real "hand": read other apps' UI and
 * click / tap / swipe it.
 *
 * Why this exists: `uitest` and `snapshot_display` are blocked for this app's
 * SELinux domain (`hishell_hap`), so the only sanctioned way to touch another
 * app's interface is an accessibility service — which needs the user to switch
 * it on in 设置 → 辅助功能 → 已安装的服务 → DshDesktop.
 *
 * Lifecycle: the system calls onConnect when the user enables the service; we
 * then start polling the node-side bridge on the `a11y` channel. onDisconnect
 * (user turns it off, or the service is killed) stops the loop.
 *
 * Declared in module.json5 as extensionAbilities[].type = "accessibility" with
 * metadata "ohos.accessibleability" -> $profile:accessibility_config.
 */

import { AccessibilityEvent, AccessibilityExtensionAbility } from '@kit.AccessibilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AccessibilityBridgeAgent } from './AccessibilityBridgeAgent';

const DOMAIN = 0x0000;
const TAG = 'DshA11y';
/** Same loopback port the UI-side agent uses; the channel separates them. */
const BRIDGE_PORT = 3131;

export default class DshAccessibilityAbility extends AccessibilityExtensionAbility {
  private agent: AccessibilityBridgeAgent | undefined = undefined;

  onConnect(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'accessibility service connected');
    try {
      this.agent = new AccessibilityBridgeAgent(this.context, BRIDGE_PORT);
      this.agent.start();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'failed to start accessibility bridge. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onDisconnect(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'accessibility service disconnected');
    if (this.agent !== undefined) {
      this.agent.stop();
      this.agent = undefined;
    }
  }

  onAccessibilityEvent(event: AccessibilityEvent): void {
    // Deliberately cheap: no per-event work, just remember the latest type so
    // `a11yLastEvent` can answer "is the service actually receiving anything?".
    if (this.agent !== undefined && event !== undefined) {
      this.agent.noteEvent(JSON.stringify(event.eventType));
    }
  }
}
