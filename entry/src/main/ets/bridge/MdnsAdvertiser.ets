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
 * mDNS advertiser for the mobile bridge (dsh-mobile-bridge, LAN port 18091).
 *
 * Why this exists (2026-10-12): the phone shell used to hardcode the PC's LAN
 * IP (192.168.101.254). The PC moved to a different network (10.10.221.48) and
 * every hardcoded candidate went stale — the phone shell could not connect at
 * all. mDNS is the platform's LAN service discovery: this advertiser announces
 * `_dshbridge._tcp` so the phone shell can resolve the current IP+port+token
 * no matter which network the PC joins.
 *
 * What is announced:
 *  - port 18091 (the bridge's remote channel, bound to 0.0.0.0, token-gated);
 *  - TXT `k=<pairing token>` so the phone can build the full URL
 *    `http://<ip>:18091/?k=<token>` / `ws://<ip>:18091/ws?k=<token>`.
 *
 * Security note: the token in TXT is visible to any mDNS listener on the LAN.
 * This matches the bridge's existing exposure (the full URL with token is
 * printed in the bridge startup log and handed out for manual pairing), so
 * discovery does not lower the bar — the token remains required on 18091.
 */

import { mdns } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';

const DOMAIN = 0x0000;
const TAG = 'MdnsAdvertiser';

/** 服务类型：手机壳用同一字符串创建 DiscoveryService。 */
const SERVICE_TYPE: string = '_dshbridge._tcp';
/** 移动端桥的 LAN 端口（远程通道，强制令牌）。 */
const BRIDGE_LAN_PORT: number = 18091;
/** 配对令牌：与桥侧 MOBILE_BRIDGE_TOKEN 一致（本机固定值）。 */
const BRIDGE_TOKEN: string = 'dshmobile2026';
/** 注册失败后的重试间隔（网络/Wi-Fi 未就绪是常态）。 */
const RETRY_MS: number = 30000;

export class MdnsAdvertiser {
  private context: common.UIAbilityContext;
  private registered: boolean = false;
  private stopped: boolean = true;
  private timer: number = -1;
  private serviceName: string;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    // 服务名带上 bundle 尾段，多设备同网络广播时互不覆盖。
    this.serviceName = 'dshbridge@' + context.abilityInfo.bundleName;
  }

  /** 开始广播；幂等。 */
  start(): void {
    if (!this.stopped) {
      return;
    }
    this.stopped = false;
    this.advertise();
  }

  /** 停止广播并注销服务。 */
  stop(): void {
    this.stopped = true;
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    if (!this.registered) {
      return;
    }
    const info = this.buildInfo();
    mdns.removeLocalService(this.context, info).then(() => {
      hilog.info(DOMAIN, TAG, 'mDNS 服务已注销');
    }).catch((e: Error) => {
      hilog.debug(DOMAIN, TAG, 'removeLocalService: %{public}s', JSON.stringify(e));
    });
    this.registered = false;
  }

  private buildInfo(): mdns.LocalServiceInfo {
    const tokenBytes: number[] = [];
    const encoder = util.TextEncoder.create('utf-8');
    const bytes = encoder.encodeInto(BRIDGE_TOKEN);
    for (let i = 0; i < bytes.length; i++) {
      tokenBytes.push(bytes[i]);
    }
    const attr: mdns.ServiceAttribute = { key: 'k', value: tokenBytes };
    const info: mdns.LocalServiceInfo = {
      serviceType: SERVICE_TYPE,
      serviceName: this.serviceName,
      port: BRIDGE_LAN_PORT,
      serviceAttribute: [attr]
    };
    return info;
  }

  private advertise(): void {
    if (this.stopped) {
      return;
    }
    const info = this.buildInfo();
    mdns.addLocalService(this.context, info).then(() => {
      this.registered = true;
      hilog.info(DOMAIN, TAG, 'mDNS 广播已上线：%{public}s :%{public}d',
        SERVICE_TYPE, BRIDGE_LAN_PORT);
    }).catch((e: Error) => {
      // Wi-Fi 未连接/组播未就绪时注册会失败，过一会儿重试。
      hilog.warn(DOMAIN, TAG, 'addLocalService 失败，%{public}dms 后重试: %{public}s',
        RETRY_MS, JSON.stringify(e));
      this.timer = setTimeout(() => {
        this.advertise();
      }, RETRY_MS);
    });
  }
}
