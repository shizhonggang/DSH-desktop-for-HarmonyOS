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
 * DSH ArkTS bridge agent.
 *
 * Why this exists: `dsh web` / the node side runs inside this app's sandbox but
 * has no ArkTS runtime, so it cannot call ArkTS-only ability APIs — most
 * importantly `startAbilityByType` (the 垂类应用选择框 / Intent Panel), and
 * `startAbility` with `flags` (uri read permission). The `aa` CLI covers a
 * plain implicit Want but has no switch for either of them.
 *
 * Transport: this agent long-polls a loopback HTTP endpoint served by the node
 * side (`bridge/bridge-server.mjs` on 127.0.0.1:3131), executes the received
 * command with the EntryAbility context, and posts the result back.
 *
 * Constraints worth knowing:
 *  - `startAbilityByType` may only be called on the main thread and while the
 *    application is in the foreground. This agent runs on the ArkTS main
 *    thread, so the only requirement is that the DshDesktop window is visible.
 *  - Nothing here needs an extra permission: `ohos.permission.INTERNET` (already
 *    declared in module.json5) covers the loopback HTTP traffic.
 */

import { common, Want, wantAgent, WantAgent, PermissionRequestResult } from '@kit.AbilityKit';
import { http, webSocket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { notificationManager } from '@kit.NotificationKit';
import { formProvider, formInfo } from '@kit.FormKit';
import { preferences } from '@kit.ArkData';
import pasteboard from '@ohos.pasteboard';
import calendarManager from '@ohos.calendarManager';
import commonEventManager from '@ohos.commonEventManager';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import bundleManager from '@ohos.bundle.bundleManager';
import reminderAgentManager from '@ohos.reminderAgentManager';
import distributedDeviceManager from '@ohos.distributedDeviceManager';
import distributedDataObject from '@ohos.data.distributedDataObject';
import deviceInfo from '@ohos.deviceInfo';
import connection from '@ohos.net.connection';
import usbManager from '@ohos.usbManager';
import thermal from '@ohos.thermal';
import workScheduler from '@ohos.resourceschedule.workScheduler';
import unifiedDataChannel from '@ohos.data.unifiedDataChannel';
import { SystemEventWatcher } from './SystemEventWatcher';
import { MdnsAdvertiser } from './MdnsAdvertiser';
import window from '@ohos.window';
import display from '@ohos.display';
import image from '@ohos.multimedia.image';
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { appManager } from '@kit.AbilityKit';
import fileIo, { WatchEvent, WatchEventListener, Watcher } from '@ohos.file.fs';
import { util } from '@kit.ArkTS';
import { textRecognition } from '@kit.CoreVisionKit';
import { statusBarManager, quickBarManager } from '@kit.DeskTopExtensionKit';
import { localChatModel } from '@kit.DataAugmentationKit';
import { textProcessing } from '@kit.NaturalLanguageKit';
import { NativeInput, NativeScreenshot, RenderCardResult } from './NativeInput';
import { textToSpeech } from '@kit.CoreSpeechKit';
import { intelligence, distributedKVStore } from '@kit.ArkData';
import { systemShare } from '@kit.ShareKit';
import { accessibility } from '@kit.AccessibilityKit';
import { deviceManager } from '@kit.DriverDevelopmentKit';
import { abilityConnectionManager } from '@kit.DistributedServiceKit';
import { emitter } from '@kit.BasicServicesKit';
import { Callback } from '@ohos.base';
import { inputEventClient, inputConsumer } from '@kit.InputKit';
import print from '@ohos.print';
import { componentSnapshot } from '@kit.ArkUI';
import { settings } from '@kit.BasicServicesKit';
import { pointer, inputDevice } from '@kit.InputKit';
import { batteryInfo } from '@kit.BasicServicesKit';
import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl';
import { Driver, ON, Component } from '@ohos.UiTest';
import DshFormAbility from '../formability/DshFormAbility';


/** v5：注入闸与指针还原的结果（ArkTS 要求对象字面量对应已声明接口） */
interface PointerOpResult {
  ok: boolean;
  code: number;
  x: number;
  y: number;
  reason: string;
}

/** v5：注入被闸拦住时的返回体 */
interface InjectionGateResult {
  ok: boolean;
  code: number;
  reason: string;
}

const DOMAIN = 0x0000;
const TAG = 'DshBridge';

/** 状态栏图标的持久化配置（dsh_statusbar prefs 的 'config' 键）。 */
interface StatusBarSavedConfig {
  title: string;
  hoverTips: string;
  menu: string;
}

const HTTP_OK = 200;
/** Delay before the next poll once the previous one has settled. */
const POLL_GAP_MS = 200;
/** Delay before retrying while the node side is unreachable / not started yet. */
const POLL_RETRY_MS = 2000;
/** Must stay below the read timeout of the long-poll request. */
const POLL_READ_TIMEOUT_MS = 30000;
/** Timeout for posting a result back to the node side. */
const POST_READ_TIMEOUT_MS = 5000;

// Same values EntryAbility uses for its background-tray notice; clicking a
// notification we publish reopens this shell window.
const SHELL_BUNDLE_NAME = 'com.example.dshdesktop';
const SHELL_ABILITY_NAME = 'EntryAbility';

/**
 * 跨设备通知同步：会话 ID 固定（两端写同一个即自动同步）。
 * 语义见 SDK：同 sessionId + 协同/可信网络 → 数据自动跨设备同步。
 */
const XDEVICE_SESSION_KEY = 'dsh_xdevice_session';
const XDEVICE_SESSION_DEFAULT = 'dsh_notify_sync_v1';

/**
 * 跨设备通知的字段载体。
 *
 * 为什么要显式声明：ArkTS 的 `arkts-no-untyped-obj-literals` 要求对象字面量
 * 必须对应已声明的 class/interface；`arkts-no-any-unknown` 又禁止用索引签名
 * 读写（`obj['seq']` 会退化成 any）。用 interface + 点号访问同时满足两条。
 */
interface XDevicePayload {
  seq: number;
  title: string;
  body: string;
  from: string;
  at: number;
  kind: string;
}

/** 设备上下线事件体（POST 给移动端桥 /event）。 */
interface DeviceStateEvent {
  type: string;
  action: string;
  deviceName: string;
  deviceId: string;
  deviceType: string;
  at: number;
}
/** EntryAbility owns id 1001 (background tray notice); stay out of its way. */
const NOTIFY_ID_BASE = 2000;
const NOTIFY_ID_SPAN = 100000;

/**
 * commonEvent name carrying a notification-button press back into this app.
 *
 * The button's WantAgent uses SEND_COMMON_EVENT (not START_ABILITY) so a press
 * is handled silently inside the app — no window is raised — and we then relay
 * `{ notifyId, buttonId }` to the node side over the existing POST /event route.
 * See .shared/artifacts/notification-action-buttons-feasibility.md §四.
 */
const NOTIFY_ACTION_EVENT = 'com.example.dshdesktop.NOTIFICATION_ACTION';
/** A published notification shows at most this many action buttons (system UI limit). */
const NOTIFY_MAX_BUTTONS = 3;

/**
 * inotify event mask for the watch probe (values are the POSIX constants from
 * `native/sysroot/usr/include/sys/inotify.h` — the SDK exposes no enum for
 * them): create + modify + moved-to + delete.
 */
const WATCH_MASK_ALL = 0x100 | 0x2 | 0x80 | 0x200;

/** A unit of work handed over by the node side. */
interface BridgeCommand {
  id: string;
  action: string;
  args: Record<string, Object>;
}

/** What we send back to the node side once a command has settled. */
interface BridgeReply {
  id: string;
  ok: boolean;
  data: string;
  error: string;
}

interface HttpReply {
  code: number;
  body: string;
}

export class BridgeAgent {
  private abilityContext: common.UIAbilityContext;
  private baseUrl: string;
  private timer: number = -1;
  private busy: boolean = false;
  private stopped: boolean = true;
  /** Counter backing auto-assigned notification ids. */
  private notificationSeq: number = 0;
  /** 常驻系统事件监听器（事件驱动自动化）。 */
  private eventWatcher: SystemEventWatcher = new SystemEventWatcher();
  /** mDNS 广播：让手机壳在任意网络下发现桥的 LAN 地址（2026-10-12 去硬编码）。 */
  private mdnsAdvertiser?: MdnsAdvertiser;
  /** commonEvent subscriber for notification-button presses (lazy, idempotent). */
  private actionSubscriber?: commonEventManager.CommonEventSubscriber;

  constructor(abilityContext: common.UIAbilityContext, port: number) {
    this.abilityContext = abilityContext;
    this.baseUrl = 'http://127.0.0.1:' + port.toString();
  }

  /** Starts the poll loop. Safe to call repeatedly. */
  start(): void {
    if (!this.stopped) {
      return;
    }
    this.stopped = false;
    hilog.info(DOMAIN, TAG, 'bridge started against %{public}s', this.baseUrl);
    // Arm the notification-button callback immediately: a press can only be
    // caught while this process is alive, so waiting for an explicit command
    // would drop every press that happens before the node side asks (observed
    // 2026-10-10: the subscribe command sat queued with agent=down while the
    // user was already clicking buttons).
    this.subscribeNotificationActions().catch((err: Error) => {
      hilog.warn(DOMAIN, TAG, 'auto-subscribe failed: %{public}s', JSON.stringify(err));
    });
    // 设备上下线是「事件源」：手机靠近/离开 PC 都值得让手机侧知道。
    this.startDeviceWatch();
    // mDNS 广播已下沉到 node 桥（dsh-mobile-bridge/mdns-responder.mjs，
    // 2026-10-12 探针实证 PTR/SRV/TXT/A 全对）：桥活=可被发现，不再依赖壳存活。
    // ArkTS 侧 MdnsAdvertiser 保留为备份实现，需要时取消下面注释即可回切。
    // if (!this.mdnsAdvertiser) {
    //   this.mdnsAdvertiser = new MdnsAdvertiser(this.abilityContext);
    // }
    // this.mdnsAdvertiser.start();
    this.schedule(0);
  }

  // ─── 设备上下线监听（想法 #2：设备上下线即事件源）──────────────────────
  //
  // 为什么放在 ArkTS 侧：distributedDeviceManager 是 ArkTS API，node 侧够不到。
  // 事件拿到后 POST 给移动端桥（127.0.0.1:18090/event），桥再广播给手机 WS。
  //
  // DeviceStateChange: UNKNOWN=0 / AVAILABLE=1 / UNAVAILABLE=2
  // ─────────────────────────────────────────────────────────────────────────

  /** 移动端桥的地址（设备事件往这里投）。 */
  private mobileBridgeUrl: string = 'http://127.0.0.1:18090';

  /** 已注册的设备监听（防止重复注册）。 */
  private deviceWatchStarted: boolean = false;

  private startDeviceWatch(): void {
    if (this.deviceWatchStarted) {
      return;
    }
    try {
      const dm: distributedDeviceManager.DeviceManager =
        distributedDeviceManager.createDeviceManager(this.abilityContext.abilityInfo.bundleName);
      dm.on('deviceStateChange', (data) => {
        try {
          const action: number = data.action as number;
          const dev = data.device;
          const stateText = action === 1 ? 'online' : (action === 2 ? 'offline' : 'change');
          hilog.info(DOMAIN, TAG, 'deviceStateChange: %{public}s %{public}s',
            stateText, dev.deviceName);
          this.postDeviceEvent({
            type: 'device_state',
            action: stateText,
            deviceName: dev.deviceName,
            deviceId: dev.deviceId,
            deviceType: dev.deviceType,
            at: Date.now()
          });
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'deviceStateChange 处理失败: %{public}s', JSON.stringify(e));
        }
      });
      this.deviceWatchStarted = true;
      hilog.info(DOMAIN, TAG, 'device watch armed');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'device watch 注册失败: %{public}s', JSON.stringify(e));
    }
  }

  /** 把设备事件 POST 给移动端桥（失败不影响主流程）。 */
  private postDeviceEvent(body: DeviceStateEvent): void {
    try {
      const req = http.createHttp();
      req.request(this.mobileBridgeUrl + '/event', {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: JSON.stringify(body),
        connectTimeout: 3000,
        readTimeout: 3000
      }).then(() => {
        req.destroy();
      }).catch((e: Error) => {
        // 桥没起是常态（用户没开手机页），静默即可
        hilog.debug(DOMAIN, TAG, 'postDeviceEvent 失败（桥可能没起）: %{public}s', JSON.stringify(e));
        req.destroy();
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'postDeviceEvent 异常: %{public}s', JSON.stringify(e));
    }
  }

  /** Stops the poll loop. */
  stop(): void {
    this.stopped = true;
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    this.mdnsAdvertiser?.stop();
    hilog.info(DOMAIN, TAG, '%{public}s', 'bridge stopped');
  }

  /**
   * Fire-and-forget event to the node side. Used for card refresh requests
   * and other UI-initiated events that don't need a response.
   */
  sendEvent(event: string, data: Map<string, Object>): void {
    const record: Record<string, Object> = {};
    data.forEach((value: Object, key: string) => {
      record[key] = value;
    });
    const body = JSON.stringify({ event, data: record });
    this.request('/event', http.RequestMethod.POST, body, POST_READ_TIMEOUT_MS).catch((err: Error) => {
      hilog.error(DOMAIN, TAG, 'sendEvent %{public}s failed: %{public}s', event, JSON.stringify(err));
    });
  }

  private schedule(delayMs: number): void {
    if (this.stopped) {
      return;
    }
    this.timer = setTimeout(() => {
      this.tick();
    }, delayMs);
  }

  private tick(): void {
    if (this.stopped) {
      return;
    }
    if (this.busy) {
      this.schedule(POLL_GAP_MS);
      return;
    }
    this.busy = true;
    this.pollOnce().then(() => {
      this.busy = false;
      this.schedule(POLL_GAP_MS);
    }).catch((err: Object) => {
      this.busy = false;
      hilog.warn(DOMAIN, TAG, 'poll failed: %{public}s', this.text(err));
      this.schedule(POLL_RETRY_MS);
    });
  }

  private async pollOnce(): Promise<void> {
    const reply = await this.request('/poll', http.RequestMethod.GET, '', POLL_READ_TIMEOUT_MS);
    if (reply.code === 0) {
      // Node side not up (yet) — surfaced as a retry by the caller.
      throw new Error('bridge server unreachable at ' + this.baseUrl);
    }
    if (reply.code !== HTTP_OK || reply.body.length === 0) {
      return;
    }
    let command: BridgeCommand;
    try {
      command = JSON.parse(reply.body) as BridgeCommand;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'malformed command: %{public}s', this.text(err));
      return;
    }
    if (command === undefined || command === null || command.id === undefined) {
      return;
    }
    const result = await this.execute(command);
    try {
      await this.request('/result', http.RequestMethod.POST, JSON.stringify(result), POST_READ_TIMEOUT_MS);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'failed to post result: %{public}s', this.text(err));
    }
  }

  private async execute(command: BridgeCommand): Promise<BridgeReply> {
    const args: Record<string, Object> = command.args === undefined || command.args === null ? {} : command.args;
    try {
      const data = await this.dispatch(command.action, args);
      hilog.info(DOMAIN, TAG, 'command %{public}s ok', command.action);
      return { id: command.id, ok: true, data: data, error: '' };
    } catch (err) {
      const message = this.text(err);
      hilog.error(DOMAIN, TAG, 'command %{public}s failed: %{public}s', command.action, message);
      return { id: command.id, ok: false, data: '', error: message };
    }
  }

  /**
   * UDMF 跨应用数据共享（统一数据管理框架）。
   *
   * 权限：核心 API（insertData/queryData/deleteData）**无需权限**。
   * 用途：与系统分享/Picker/拖拽通道打通，跨应用传结构化数据。
   *
   * args: { text, key? }  —— 写入一段纯文本到 UDMF 通道
   */
  private async udmfShare(args: Record<string, Object>): Promise<string> {
    const text = this.stringArg(args, 'text');
    const key = this.stringArg(args, 'key');
    try {
      const record = new unifiedDataChannel.PlainText();
      record.textContent = text;
      const data = new unifiedDataChannel.UnifiedData(record);
      const options: unifiedDataChannel.Options = {
        intention: unifiedDataChannel.Intention.DATA_HUB,
        key: key.length > 0 ? key : undefined
      };
      const id = await unifiedDataChannel.insertData(options, data);
      return JSON.stringify({ ok: true, key: id, textLength: text.length });
    } catch (err) {
      return JSON.stringify({ ok: false, error: this.text(err) });
    }
  }

  /** 从 UDMF 读取数据。args: { key } */
  private async udmfQuery(args: Record<string, Object>): Promise<string> {
    const key = this.stringArg(args, 'key');
    try {
      const options: unifiedDataChannel.Options = {
        intention: unifiedDataChannel.Intention.DATA_HUB,
        key: key.length > 0 ? key : undefined
      };
      const list: unifiedDataChannel.UnifiedData[] = await unifiedDataChannel.queryData(options);
      const out: string[] = [];
      for (const d of list) {
        const records = d.getRecords();
        for (const r of records) {
          const pt = r as unifiedDataChannel.PlainText;
          const content = pt.textContent;
          if (content !== undefined) {
            out.push(content);
          }
        }
      }
      return JSON.stringify({ ok: true, count: out.length, texts: out });
    } catch (err) {
      return JSON.stringify({ ok: false, error: this.text(err) });
    }
  }

  /**
   * 注册条件触发的后台任务（WorkScheduler）。
   *
   * 与长时任务（TASK_KEEPING）的区别：
   *   - 长时任务：应用持续运行（受后台 CPU 限流，实测 ~2.3 轮询/分）
   *   - WorkScheduler：**系统按条件调度**（网络恢复/充电/定时），应用按需被拉起
   *     → 更适合"到条件才干活"，不占用常驻配额
   *
   * 权限：无需权限。
   * 注意：实际执行体需声明 WorkSchedulerExtensionAbility 并在 module.json5 注册。
   *
   * args: { workId?, repeatCycleSeconds?, networkType?, isCharging? }
   */
  private async scheduleWork(args: Record<string, Object>): Promise<string> {
    const workId = this.numberArg(args, 'workId') > 0 ? this.numberArg(args, 'workId') : 1001;
    const repeat = this.numberArg(args, 'repeatCycleSeconds');
    const info: workScheduler.WorkInfo = {
      workId: workId,
      bundleName: this.abilityContext.abilityInfo.bundleName,
      abilityName: 'DshWorkSchedulerAbility',
      isPersisted: true
    };
    if (repeat > 0) {
      info.repeatCycleTime = repeat;
      info.isRepeat = true;
    }
    try {
      workScheduler.startWork(info);
      return JSON.stringify({ ok: true, workId: workId, repeatCycleTime: repeat });
    } catch (err) {
      return JSON.stringify({ ok: false, error: this.text(err) });
    }
  }

  /** 列出已注册的 WorkScheduler 任务。 */
  private async listWorks(): Promise<string> {
    try {
      const works: workScheduler.WorkInfo[] = await workScheduler.obtainAllWorks();
      const out: string[] = [];
      for (const w of works) {
        out.push(JSON.stringify({
          workId: w.workId,
          bundleName: w.bundleName,
          abilityName: w.abilityName,
          isRepeat: w.isRepeat,
          repeatCycleTime: w.repeatCycleTime
        }));
      }
      return JSON.stringify({ ok: true, count: works.length, works: out });
    } catch (err) {
      return JSON.stringify({ ok: false, error: this.text(err) });
    }
  }

  /**
   * 设备感知快照：设备信息 / 网络状态 / 电池等（小艺建议的"感知 API 补齐"）。
   *
   * 权限：GET_NETWORK_INFO（normal，已授予）；deviceInfo 基础字段无需权限。
   */
  private async devicePerception(args: Record<string, Object>): Promise<string> {
    const out: Record<string, Object> = {};
    // 设备静态信息（无需权限）
    try {
      out['brand'] = deviceInfo.brand;
      out['productModel'] = deviceInfo.productModel;
      out['marketName'] = deviceInfo.marketName;
      out['deviceType'] = deviceInfo.deviceType;
      out['osFullName'] = deviceInfo.osFullName;
      out['sdkApiVersion'] = deviceInfo.sdkApiVersion;
      out['udid'] = '';   // udid 需权限，不取
    } catch (e) {
      out['deviceInfoError'] = this.text(e);
    }
    // 网络：当前是否联网 + 连接类型
    try {
      const net = connection.getDefaultNetSync();
      out['defaultNetHandle'] = net.netId;
      const caps: connection.NetCapabilities = connection.getNetCapabilitiesSync(net);
      out['netCapabilities'] = JSON.stringify(caps);
    } catch (e) {
      out['netError'] = this.text(e);
    }
    return JSON.stringify({ ok: true, data: out });
  }

  /**
   * USB 设备列表（无需权限）。
   * 用途：外设感知（U 盘/键鼠/串口等），配合自动化判断可用设备。
   */
  private async usbDevices(): Promise<string> {
    try {
      const list: usbManager.USBDevice[] = usbManager.getDevices();
      const devs: string[] = [];
      for (const d of list) {
        devs.push(JSON.stringify({
          busNum: d.busNum,
          devAddress: d.devAddress,
          name: d.name,
          vendorId: d.vendorId,
          productId: d.productId,
          manufacturerName: d.manufacturerName,
          productName: d.productName,
          clazz: d.clazz
        }));
      }
      return JSON.stringify({ ok: true, count: list.length, devices: devs });
    } catch (err) {
      return JSON.stringify({ ok: false, error: this.text(err) });
    }
  }

  /**
   * 温度/热等级（无需权限）。
   * 用途：高温时降级/暂停密集自动化，避免触发系统限流。
   */
  private async thermalLevel(): Promise<string> {
    try {
      const level = thermal.getThermalLevel();
      return JSON.stringify({ ok: true, thermalLevel: level });
    } catch (err) {
      return JSON.stringify({ ok: false, error: this.text(err) });
    }
  }

  /**
   * 列出生效的跨设备（分布式设备发现）。
   *
   * 权限：DISTRIBUTED_DATASYNC（normal 级 + user_grant，已授予，免 ACL）。
   *
   * 背景：小艺指出「三方无跨设备 API 入口」是错的——@ohos.distributedDeviceManager
   * 是公开 API，可发现同账号设备、可信认证、监听上下线。
   * 本 action 实测这一通路。
   */
  private async listDistributedDevices(): Promise<string> {
    try {
      const dm: distributedDeviceManager.DeviceManager =
        distributedDeviceManager.createDeviceManager(this.abilityContext.abilityInfo.bundleName);
      const localName = dm.getLocalDeviceName();
      const localId = dm.getLocalDeviceNetworkId();
      let devices: string[] = [];
      try {
        const list: distributedDeviceManager.DeviceBasicInfo[] = dm.getAvailableDeviceListSync();
        for (const d of list) {
          devices.push(JSON.stringify({
            deviceId: d.deviceId,
            deviceName: d.deviceName,
            deviceType: d.deviceType,
            networkId: d.networkId
          }));
        }
      } catch (e) {
        devices.push('getAvailableDeviceListSync failed: ' + this.text(e));
      }
      return JSON.stringify({
        ok: true,
        localName: localName,
        localNetworkId: localId,
        discoveredCount: devices.length,
        devices: devices
      });
    } catch (err) {
      return JSON.stringify({ ok: false, error: this.text(err) });
    }
  }

  // ─── 跨设备通知同步（distributedDataObject 当传输层） ─────────────────────
  //
  // 原理：两端 DSH 各建一个分布式数据对象，setSessionId 写同一个会话 ID，
  // 软总线自动同步（免网络配置、免令牌）。A 机写字段 → B 机 on('change') 触发
  // → 本地 de_notify(channels:'web') 弹系统通知。
  //
  // 权限：DISTRIBUTED_DATASYNC（normal + user_grant，module.json5 已声明）。
  //
  // 字段约定（source 对象的初始属性，后续直接赋值即同步）：
  //   seq      : 递增序号（去重用）
  //   title    : 通知标题
  //   body     : 通知正文
  //   from     : 来源设备名
  //   at       : 写入时间戳 ms
  //   kind     : 'notify' | 'ping' | 'device_online' | 'device_offline'
  // ─────────────────────────────────────────────────────────────────────────

  /** 当前活跃的分布式数据对象（null = 未启动）。 */
  private dsoObj: distributedDataObject.DataObject | null = null;
  /** 本地镜像：写入时同步更新，读取时从这里取（规避 ArkTS 禁 any 索引）。 */
  private dsoMirror: XDevicePayload = {
    seq: 0, title: '', body: '', from: '', at: 0, kind: 'ping'
  };
  /** 本端最近一次处理的 seq（防止重复弹通知）。 */
  private dsoLastSeq: number = 0;
  /** 本端写入计数（也是 seq 的来源）。 */
  private dsoWriteCount: number = 0;
  /** change 回调引用（off 时要传同一个函数）。 */
  private dsoChangeCb: ((sessionId: string, fields: string[]) => void) | null = null;
  /** status 回调引用。 */
  private dsoStatusCb: ((sessionId: string, networkId: string, status: string) => void) | null = null;

  /**
   * dsoStart：创建分布式数据对象并加入会话。
   *
   * args.sessionId 可选；缺省用固定默认值（两端写同一个即同步）。
   * 返回当前会话 ID 与初始字段。
   */
  private async dsoStart(args: Record<string, Object>): Promise<string> {
    try {
      if (this.dsoObj !== null) {
        return JSON.stringify({ ok: true, already: true, sessionId: this.dsoSessionIdCached() });
      }
      const ctx = this.abilityContext;
      // 用本地镜像当 source；后续读写都走 dsoMirror，规避 ArkTS 禁 any 索引
      this.dsoMirror = { seq: 0, title: '', body: '', from: '', at: 0, kind: 'ping' };
      const obj: distributedDataObject.DataObject =
        distributedDataObject.create(ctx, this.dsoMirror);
      const sid = this.stringArg(args, 'sessionId') || XDEVICE_SESSION_DEFAULT;
      await obj.setSessionId(sid);

      // 监听字段变更 → 远端写入时触发
      this.dsoChangeCb = (sessionId: string, fields: string[]) => {
        this.onDsoChange(obj, fields);
      };
      obj.on('change', this.dsoChangeCb);

      // 监听对端上下线
      this.dsoStatusCb = (sessionId: string, networkId: string, status: string) => {
        hilog.info(DOMAIN, TAG, 'dso status: %{public}s %{public}s', networkId, status);
      };
      obj.on('status', this.dsoStatusCb);

      this.dsoObj = obj;
      return JSON.stringify({
        ok: true,
        sessionId: sid,
        fields: ['seq', 'title', 'body', 'from', 'at', 'kind'],
        note: 'same sessionId on peer device auto-syncs via softbus'
      });
    } catch (err) {
      return JSON.stringify({ ok: false, error: this.text(err) });
    }
  }

  /** dsoStop：退出会话并释放对象。 */
  private async dsoStop(): Promise<string> {
    try {
      if (this.dsoObj === null) {
        return JSON.stringify({ ok: true, already: false });
      }
      if (this.dsoChangeCb) {
        this.dsoObj.off('change', this.dsoChangeCb);
        this.dsoChangeCb = null;
      }
      if (this.dsoStatusCb) {
        this.dsoObj.off('status', this.dsoStatusCb);
        this.dsoStatusCb = null;
      }
      await this.dsoObj.setSessionId('');
      this.dsoObj = null;
      return JSON.stringify({ ok: true, stopped: true });
    } catch (err) {
      return JSON.stringify({ ok: false, error: this.text(err) });
    }
  }

  /** dsoWrite：写一条通知（本地 + 自动同步到对端）。 */
  private async dsoWrite(args: Record<string, Object>): Promise<string> {
    try {
      if (this.dsoObj === null) {
        return JSON.stringify({ ok: false, error: 'not started, call dsoStart first' });
      }
      this.dsoWriteCount++;
      const title = this.stringArg(args, 'title') || 'DSH 跨设备通知';
      const body = this.stringArg(args, 'body') || '';
      const kind = this.stringArg(args, 'kind') || 'notify';
      const from = this.stringArg(args, 'from') || deviceInfo.productModel || 'unknown';

      // 直接改本地镜像即触发同步（SDK 机制：source 对象属性变更自动广播）
      this.dsoMirror.seq = this.dsoWriteCount;
      this.dsoMirror.title = title;
      this.dsoMirror.body = body;
      this.dsoMirror.kind = kind;
      this.dsoMirror.from = from;
      this.dsoMirror.at = Date.now();

      return JSON.stringify({ ok: true, seq: this.dsoWriteCount, title, body, kind, from });
    } catch (err) {
      return JSON.stringify({ ok: false, error: this.text(err) });
    }
  }

  /** dsoRead：读当前字段（调试用）。 */
  private async dsoRead(): Promise<string> {
    try {
      if (this.dsoObj === null) {
        return JSON.stringify({ ok: false, error: 'not started' });
      }
      const m = this.dsoMirror;
      return JSON.stringify({
        ok: true,
        seq: m.seq,
        title: m.title,
        body: m.body,
        kind: m.kind,
        from: m.from,
        at: m.at,
        localWriteCount: this.dsoWriteCount,
        lastProcessedSeq: this.dsoLastSeq
      });
    } catch (err) {
      return JSON.stringify({ ok: false, error: this.text(err) });
    }
  }

  /** dsoStatus：查询对象是否活跃 + 当前 seq。 */
  private async dsoStatus(): Promise<string> {
    return JSON.stringify({
      ok: true,
      active: this.dsoObj !== null,
      sessionId: this.dsoSessionIdCached(),
      localWriteCount: this.dsoWriteCount,
      lastProcessedSeq: this.dsoLastSeq
    });
  }

  /** 返回缓存的会话 ID（未启动时为空串）。 */
  private dsoSessionIdCached(): string {
    // DataObject 没有 getter，用最后一次 setSessionId 的值；这里简化返回默认值
    return this.dsoObj !== null ? XDEVICE_SESSION_DEFAULT : '';
  }

  /**
   * 对端写入字段时触发。seq 去重后回传桥（bridge 再决定要不要 de_notify）。
   * 注意：这里只负责把事件抛给 node 侧；真正的弹通知动作在 node 侧做，
   * 因为 de_notify 是 node 插件能力，ArkTS 壳里没有。
   */
  private onDsoChange(obj: distributedDataObject.DataObject, fields: string[]): void {
    try {
      // 从本地镜像读（SDK 同步时已把远端值写进 source 对象）
      const m = this.dsoMirror;
      const seq = m.seq;
      if (seq <= this.dsoLastSeq) {
        return; // 自己写的回声或乱序，忽略
      }
      this.dsoLastSeq = seq;
      const title = m.title;
      const body = m.body;
      const kind = m.kind;
      const from = m.from;
      const at = m.at;
      hilog.info(DOMAIN, TAG,
        'dso change: seq=%{public}d kind=%{public}s from=%{public}s title=%{public}s',
        seq, kind, from, title);
      // 把事件写进 bridge 的事件通道，node 侧轮询到后 de_notify
      this.postEvent('xdevice_notify', JSON.stringify({
        seq, title, body, kind, from, at,
        receivedAt: Date.now()
      }));
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'onDsoChange failed: %{public}s', this.text(e));
    }
  }

  /**
   * 把事件 POST 到 node 侧 bridge-server 的 /event 端点。
   * bridge-server 已有这个端点（通知按钮事件就走这里）。
   */
  private postEvent(eventType: string, payload: string): void {
    try {
      const req = http.createHttp();
      const url = 'http://127.0.0.1:3131/event';
      // bridge-server /event expects {event, data} (2026-10-12 fix: this used to
      // send {type, payload}, which landed as empty events in ui-events.json).
      let data: Object = payload;
      try {
        data = JSON.parse(payload) as Object;
      } catch { /* keep raw string */ }
      req.request(url, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: JSON.stringify({ event: eventType, data: data }),
        readTimeout: POST_READ_TIMEOUT_MS
      }).then(() => {
        req.destroy();
      }).catch(() => {
        req.destroy();
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'postEvent failed: %{public}s', this.text(e));
    }
  }

  /**
   * 发布系统级提醒（闹钟/日历/计时器类）。
   *
   * 权限：PUBLISH_AGENT_REMINDER（**normal 级 + system_grant，已授予，免 ACL**）。
   * 这推翻了「DSH 无法操作系统闹钟/计时器」的判断——reminderAgent 就是官方通路。
   *
   * args: { title, content, minutes? , hour?, minute?, type?: 'timer'|'calendar'|'alarm' }
   *   默认发布一个延时提醒（timer 型，minutes 分钟后触发）。
   */
  private async publishReminder(args: Record<string, Object>): Promise<string> {
    const title = this.stringArg(args, 'title');
    const content = this.stringArg(args, 'content');
    const minutes = this.numberArg(args, 'minutes');
    const delay = minutes > 0 ? minutes * 60 : 60;   // 秒，默认 1 分钟后

    const kind = this.stringArg(args, 'type');
    if (kind === 'alarm' || kind === 'calendar') {
      // 日历/闹钟型：用 dateTime 指定绝对时间
      const when = new Date(Date.now() + delay * 1000);
      const calReq: reminderAgentManager.ReminderRequestCalendar = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
        dateTime: {
          year: when.getFullYear(),
          month: when.getMonth() + 1,
          day: when.getDate(),
          hour: when.getHours(),
          minute: when.getMinutes(),
          second: when.getSeconds()
        },
        title: title.length > 0 ? title : 'DSH 提醒',
        content: content.length > 0 ? content : '任务提醒',
        notificationId: 2002,
        slotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
        tapDismissed: true
      };
      try {
        const calId = await reminderAgentManager.publishReminder(calReq);
        return JSON.stringify({ ok: true, reminderId: calId, kind: 'calendar', at: when.toISOString() });
      } catch (err) {
        return JSON.stringify({ ok: false, kind: 'calendar', error: this.text(err) });
      }
    }
    const req: reminderAgentManager.ReminderRequestTimer = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_TIMER,
      triggerTimeInSeconds: delay,
      title: title.length > 0 ? title : 'DSH 提醒',
      content: content.length > 0 ? content : '任务提醒',
      // 补全常见必填项（缺 slotType/notificationId 可能被判无效）
      notificationId: 2001,
      slotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      tapDismissed: true,
      ringDuration: 3,
      snoozeTimes: 0
    };
    try {
      const id = await reminderAgentManager.publishReminder(req);
      return JSON.stringify({ ok: true, reminderId: id, triggerInSeconds: delay });
    } catch (err) {
      return JSON.stringify({ ok: false, error: this.text(err) });
    }
  }

  /** 取消提醒。args: { id: number } */
  private async cancelReminder(args: Record<string, Object>): Promise<string> {
    const id = this.numberArg(args, 'id');
    if (id <= 0) {
      return JSON.stringify({ ok: false, error: 'missing required arg: id' });
    }
    try {
      await reminderAgentManager.cancelReminder(id);
      return JSON.stringify({ ok: true, cancelled: id });
    } catch (err) {
      return JSON.stringify({ ok: false, error: this.text(err) });
    }
  }

  /**
   * 常驻系统事件监听（事件驱动自动化的底座）。
   *
   * 与 commonEventProbe 的区别：probe 是阻塞式一次性探测；
   * watchEvents 是常驻订阅 + 随时查询，适合长跑自动化。
   *
   * args: { op: 'start'|'stop'|'read'|'clear'|'status', sinceMs?: number, events?: string[] }
   */
  private async watchEvents(args: Record<string, Object>): Promise<string> {
    const op = this.stringArg(args, 'op');
    if (op === 'start') {
      await this.eventWatcher.start();
      return this.eventWatcher.status();
    }
    if (op === 'stop') {
      this.eventWatcher.unsubscribe();
      return this.eventWatcher.status();
    }
    if (op === 'read') {
      const since = this.numberArg(args, 'sinceMs');
      const list = this.eventWatcher.read(since);
      const out: string[] = [];
      for (const e of list) {
        out.push(JSON.stringify({ at: e.at, event: e.event, code: e.code }));
      }
      return JSON.stringify({ count: list.length, events: out });
    }
    if (op === 'clear') {
      const n = this.eventWatcher.clear();
      return JSON.stringify({ cleared: n });
    }
    return this.eventWatcher.status();
  }

  /**
   * 按 URI 反查能力信息（谁处理这个 scheme）。
   *
   * 权限：GET_ABILITY_INFO（**ACL 已获批**，实测已授予）。
   * API：`bundleManager.getAbilityInfo(uri, abilityFlags)` —— 与 skills 里 uris 字段同格式。
   *
   * 用途：
   *   - 解析 `mailto:` / `https://` 等深链由哪个应用处理（自动化选路）
   *   - 提前得知意图会被谁接管，避免打开错误应用
   *
   * args: { uri: string, flags?: number }
   */
  private async resolveAbilityByUri(args: Record<string, Object>): Promise<string> {
    const uri = this.stringArg(args, 'uri');
    if (uri.length === 0) {
      return JSON.stringify({ ok: false, error: 'missing required arg: uri' });
    }
    // GET_ABILITY_INFO_DEFAULT = 0（避免误用 FA 模式的枚举）
    const flags = this.numberArg(args, 'flags');
    try {
      const infos: bundleManager.AbilityInfo[] = await bundleManager.getAbilityInfo(uri, flags);
      const out: string[] = [];
      for (const info of infos) {
        out.push(JSON.stringify({
          bundleName: info.bundleName,
          moduleName: info.moduleName,
          name: info.name,
          label: info.label,
          enabled: info.enabled
        }));
      }
      return JSON.stringify({ ok: true, uri: uri, count: infos.length, abilities: out });
    } catch (err) {
      return JSON.stringify({ ok: false, uri: uri, error: this.text(err) });
    }
  }

  /**
   * 列出已安装应用（含版本/类型），用于能力盘点与选路。
   * 权限：GET_BUNDLE_INFO（normal 级，已授予）。不支持 userId 遍历，仅当前用户。
   *
   * args: { limit?: number, systemOnly?: boolean }
   */
  private async getAllBundleInfo(): Promise<string> {
    try {
      const flag = bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION;
      const infos: bundleManager.BundleInfo[] = await bundleManager.getInstalledBundleList(flag);
      const names: string[] = [];
      for (const b of infos) {
        const app = b.appInfo;
        names.push(JSON.stringify({
          bundleName: b.name,
          label: app !== undefined ? app.label : '',
          systemApp: app !== undefined ? app.systemApp : false,
          versionName: b.versionName
        }));
      }
      names.sort();
      return JSON.stringify({ ok: true, count: infos.length, bundles: names });
    } catch (err) {
      return JSON.stringify({ ok: false, error: this.text(err) });
    }
  }

  /**
   * 申请长时任务（ContinuousTask）—— 让应用在后台持续运行。
   *
   * 权限：KEEP_BACKGROUND_RUNNING（normal 级 + system_grant，已授予，**无需 ACL**）。
   *
   * ⚠️ 关键细节（SDK 原文）：
   *   - `TASK_KEEPING` 在 API 20 及以前**仅限 PC/2in1 设备**；本机正是 2in1 → 适用
   *   - 只有"非 PC/2in1 设备用 MODE_TASK_KEEPING"或"MODE_SPECIAL_SCENARIO_PROCESSING"
   *     才需要 ACL 权限 KEEP_BACKGROUND_RUNNING_SYSTEM
   *   - 我们是 PC → **不需要任何 ACL**
   *
   * 用途：桥接层/自动化任务在后台持续运行，不被系统挂起。
   */
  private async startContinuousTask(args: Record<string, Object>): Promise<string> {
    // 遍历所有 BackgroundMode，找出系统真正接受的（TASK_KEEPING 可能三方受限）
    const candidates: backgroundTaskManager.BackgroundMode[] = [
      backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
      backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
      backgroundTaskManager.BackgroundMode.AUDIO_RECORDING,
      backgroundTaskManager.BackgroundMode.LOCATION,
      backgroundTaskManager.BackgroundMode.BLUETOOTH_INTERACTION,
      backgroundTaskManager.BackgroundMode.MULTI_DEVICE_CONNECTION,
      backgroundTaskManager.BackgroundMode.TASK_KEEPING
    ];
    const tried: string[] = [];
    for (const mode of candidates) {
      try {
        const want: Want = {
          bundleName: this.abilityContext.abilityInfo.bundleName,
          abilityName: this.abilityContext.abilityInfo.name
        };
        const info: wantAgent.WantAgentInfo = {
          wants: [want],
          operationType: wantAgent.OperationType.START_ABILITY,
          requestCode: 0
        };
        const agent = await wantAgent.getWantAgent(info);
        await backgroundTaskManager.startBackgroundRunning(this.abilityContext, mode, agent);
        return JSON.stringify({ ok: true, acceptedMode: mode, triedAll: tried });
      } catch (err) {
        tried.push(this.text(err));
      }
    }
    return JSON.stringify({ ok: false, tried: tried });
    /*
    try {
      const mode: backgroundTaskManager.BackgroundMode = backgroundTaskManager.BackgroundMode.TASK_KEEPING;
      // wantAgent：任务在通知栏可见，点击可回到本应用
      const want: Want = {
        bundleName: this.abilityContext.abilityInfo.bundleName,
        abilityName: this.abilityContext.abilityInfo.name
      };
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0
      };
      const agent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(this.abilityContext, mode, agent);
      return JSON.stringify({ ok: true, mode: 'TASK_KEEPING' });
    } catch (err) {
      return JSON.stringify({ ok: false, error: this.text(err) });
    }
    */
  }

  /** 停止长时任务。 */
  private async stopContinuousTask(): Promise<string> {
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.abilityContext);
      return JSON.stringify({ ok: true, stopped: true });
    } catch (err) {
      return JSON.stringify({ ok: false, error: this.text(err) });
    }
  }

  /**
   * 探测 CommonEvent 订阅能力（COMMONEVENT_STICKY 权限已授予）。
   *
   * 目的：验证三方应用在**不申请 ACL** 的前提下能否收到系统公共事件。
   * 之前结论是"CommonEventService 被 ACL 拦住"，但 COMMONEVENT_STICKY 是
   * normal 级且已授予——所以需要实测它到底解锁了什么。
   *
   * args: { events?: string[], waitMs?: number, publishTest?: boolean }
   *   - 订阅给定事件（默认一组常见系统事件）并等待 waitMs 毫秒收集
   *   - publishTest=true 时自己发一条自定义事件，验证订阅链路本身通不通
   */
  private async commonEventProbe(args: Record<string, Object>): Promise<string> {
    const waitMs = this.numberArg(args, 'waitMs') > 0 ? this.numberArg(args, 'waitMs') : 3000;
    // 一组候选事件：涵盖系统状态/包管理/电源/网络/用户等常见广播
    const events: string[] = [
      'usual.event.SCREEN_ON',
      'usual.event.SCREEN_OFF',
      'usual.event.USER_UNLOCKED',
      'usual.event.PACKAGE_ADDED',
      'usual.event.PACKAGE_REMOVED',
      'usual.event.BATTERY_CHANGED',
      'usual.event.CONNECTIVITY_CHANGE',
      'usual.event.AIRPLANE_MODE',
      'usual.event.TIME_TICK',
      'usual.event.TIME_SET',
      'usual.event.TIMEZONE_CHANGED',
      'usual.event.LOCALE_CHANGED',
      'usual.event.DEVICE_IDLE_MODE_CHANGED',
      'usual.event.ACCOUNT_CHANGED'
    ];

    const received: string[] = [];
    const info: commonEventManager.CommonEventSubscribeInfo = {
      events: events,
      publisherPermission: ''
    };

    let subscriber: commonEventManager.CommonEventSubscriber | undefined = undefined;
    try {
      subscriber = await commonEventManager.createSubscriber(info);
      const cb = (data: commonEventManager.CommonEventData): void => {
        received.push(data.event + '|code=' + data.code);
      };
      await commonEventManager.subscribeToEvent(subscriber, cb);

      // 可选：自己发一条自定义事件，验证订阅链路（不依赖系统）
      const selfPublished = this.booleanArg(args, 'publishTest');
      if (selfPublished) {
        const payload: commonEventManager.CommonEventPublishData = { code: 0, data: 'self-test' };
        await new Promise<void>((resolve: () => void) => {
          commonEventManager.publish('com.example.dshdesktop.probe', payload,
            (err: BusinessError) => { resolve(); });
        });
      }

      await this.sleep(waitMs);

      // 收尾：取消订阅，避免泄漏
      if (subscriber !== undefined) {
        commonEventManager.unsubscribe(subscriber);
      }
      return JSON.stringify({
        subscribed: events.length,
        receivedCount: received.length,
        received: received,
        note: 'received=0 不代表订阅失败，可能只是等待期间没有系统事件发生'
      });
    } catch (err) {
      if (subscriber !== undefined) {
        try { commonEventManager.unsubscribe(subscriber); } catch (e) { /* ignore */ }
      }
      return JSON.stringify({ error: this.text(err), subscribedAttempt: events.length });
    }
  }

  /** 简单的等待辅助。 */
  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => { resolve(); }, ms);
    });
  }

  /**
   * 读取日历（官方 calendarManager API）。
   *
   * 权限：READ_CALENDAR（normal 级 + user_grant，已在启动时弹窗授予）。
   * 数据源是 com.huawei.hmos.calendardata 的沙箱（连 shell 都读不到），
   * 只能通过应用内的日历 API 访问。见 skill permission-tiers.md §5。
   *
   * args: { limit?: number }
   * 返回：日历账号清单 + 每个账号下近期日程条数
   */
  private async calendarQuery(args: Record<string, Object>): Promise<string> {
    const limit = this.numberArg(args, 'limit');
    const manager = calendarManager.getCalendarManager(this.abilityContext);
    const calendars: calendarManager.Calendar[] = await manager.getAllCalendars();
    const summary: string[] = [];
    let eventTotal = 0;
    for (const cal of calendars) {
      let count = 0;
      try {
        const events: calendarManager.Event[] = await cal.getEvents();
        count = events.length;
        eventTotal += count;
        // 只回报前 limit 条标题，避免响应过大
        const titles: string[] = [];
        for (const ev of events.slice(0, limit)) {
          titles.push(ev.title !== undefined ? ev.title : '(untitled)');
        }
        summary.push(JSON.stringify({
          eventCount: count,
          sampleTitles: titles
        }));
      } catch (err) {
        count = -1;
        summary.push(JSON.stringify({ error: this.text(err) }));
      }
    }
    return JSON.stringify({
      calendarCount: calendars.length,
      eventTotal: eventTotal,
      calendars: summary
    });
  }

  /**
   * 查询应用内权限授予状态。
   *
   * 逐个 checkAccessToken，区分三种情况：
   *   - 已授予（user_grant 已弹窗同意 / system_grant 自动）
   *   - 未授予且可申请（user_grant 尚未弹窗）—— 用 permission-tiers.md 的清单
   *   - 未授予且不可申请（ACL 未获批）
   *
   * 用途：自动化开始前先自检能力边界，避免"调用失败才发现没权限"。
   */
  private async getPermissionStatus(): Promise<string> {
    const manager = abilityAccessCtrl.createAtManager();
    const tokenId = this.abilityContext.applicationInfo.accessTokenId;

    // 关注清单：能力直接依赖的关键权限（不含纯体验类）
    const tracked: string[] = [
      'ohos.permission.INTERNET',
      'ohos.permission.CUSTOM_SCREEN_CAPTURE',
      'ohos.permission.READ_PASTEBOARD',
      'ohos.permission.GET_ABILITY_INFO',
      'ohos.permission.READ_CALENDAR',
      'ohos.permission.WRITE_CALENDAR',
      'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY',
      'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY',
      'ohos.permission.COMMONEVENT_STICKY',
      'ohos.permission.PUBLISH_AGENT_REMINDER',
      'ohos.permission.TIMEOUT_SCREENOFF_DISABLE_LOCK',
      'ohos.permission.KEEP_BACKGROUND_RUNNING',
      'ohos.permission.PRIVACY_WINDOW',
      'ohos.permission.WINDOW_TOPMOST'
    ];

    const granted: string[] = [];
    const denied: string[] = [];
    for (const name of tracked) {
      try {
        const status = await manager.checkAccessToken(tokenId, name as Permissions);
        if (status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          granted.push(name);
        } else {
          denied.push(name);
        }
      } catch (err) {
        denied.push(name);
      }
    }
    return JSON.stringify({
      granted: granted,
      denied: denied,
      aclBacked: ['ohos.permission.READ_PASTEBOARD', 'ohos.permission.GET_ABILITY_INFO']
    });
  }

  /**
   * 主动触发 user_grant 权限申请弹窗（用户不在时会静默失败）。
   * 正常路径是 EntryAbility.onWindowStageCreate 自动申请；此 action 供补申请用。
   */
  private async requestPermissions(): Promise<string> {
    const manager = abilityAccessCtrl.createAtManager();
    const list: Permissions[] = [
      'ohos.permission.READ_CALENDAR',
      'ohos.permission.WRITE_CALENDAR',
      'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY',
      'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY'
    ];
    const result = await manager.requestPermissionsFromUser(this.abilityContext, list);
    return JSON.stringify({ authResults: result.authResults, permissions: result.permissions });
  }

  private dispatch(action: string, args: Record<string, Object>): Promise<string> {
    if (action === 'ping') {
      return Promise.resolve('{"pong":true}');
    }
    if (action === 'startAbilityByType') {
      return this.startAbilityByType(args);
    }
    if (action === 'startAbility') {
      return this.startAbility(args);
    }
    if (action === 'openLink') {
      return this.openLink(args);
    }
    if (action === 'notify') {
      return this.notify(args);
    }
    if (action === 'subscribeNotificationActions') {
      return this.subscribeNotificationActions();
    }
    if (action === 'dismissNotification') {
      return this.dismissNotification(args);
    }
    if (action === 'updateCard') {
      return this.updateCard(args);
    }
    if (action === 'setClipboard') {
      return this.setClipboard(args);
    }
    if (action === 'getClipboard') {
      return this.getClipboard();
    }
    if (action === 'uiTestProbe') {
      return this.uiTestProbe();
    }
    if (action === 'aclProbe') {
      return this.aclProbe(args);
    }
    if (action === 'screenRecordProbe') {
      return this.screenRecordProbe();
    }
    if (action === 'volume') {
      return this.volume(args);
    }
    if (action === 'killProcess') {
      return this.killProcess(args);
    }
    if (action === 'windowLayoutAll') {
      return this.windowLayoutAll(args);
    }
    if (action === 'clipboardWatch') {
      return this.clipboardWatch(args);
    }
    if (action === 'clipboardRich') {
      return this.clipboardRich();
    }
    if (action === 'hotkeyWatch') {
      return this.hotkeyWatch(args);
    }
    if (action === 'fsWatch') {
      return this.fsWatch(args);
    }
    if (action === 'printFile') {
      return this.printFile(args);
    }
    if (action === 'offscreenRender') {
      return this.offscreenRender(args);
    }
    if (action === 'deviceStatus') {
      return this.deviceStatus();
    }
    if (action === 'pointerVisible') {
      return this.pointerVisible(args);
    }
    if (action === 'settingsRead') {
      return this.settingsRead(args);
    }
    // ===== NDK-only 能力（libdshnative.so napi；session-98608bdc 追加，勿动）=====
    if (action === 'ndkPointerLocation') {
      return this.ndkResult(NativeInput.getPointerLocation());
    }
    if (action === 'ndkRequestInjection') {
      return this.ndkResult(NativeInput.requestInjection());
    }
    if (action === 'ndkInjectionStatus') {
      return this.ndkResult(NativeInput.queryInjectionStatus());
    }
    // v5：三个注入 action 统一走「空闲闸」——用户正在操作时不插队（args.force=true 跳过）
    if (action === 'ndkInjectKey') {
      return this.ndkInjectKey(args);
    }
    if (action === 'ndkInjectMouse') {
      return this.ndkInjectMouse(args);
    }
    if (action === 'ndkInjectTouch') {
      return this.ndkInjectTouch(args);
    }
    // DDK：枚举外接 HID 设备（ACCESS_EXTENSIONAL_DEVICE_DRIVER，normal 级）
    if (action === 'driverDevices') {
      return Promise.resolve(this.driverDevices());
    }
    // DDK：HID 探针（打开设备 + 读原始报文；需 ACCESS_DDK_HID ACL）
    if (action === 'hidProbe') {
      return Promise.resolve(JSON.stringify(NativeInput.hidProbe(
        this.numberArg(args, 'deviceId'),
        args['interfaceIndex'] === undefined ? 0 : this.numberArg(args, 'interfaceIndex'))));
    }
    if (action === 'ndkPointerSave') {
      return Promise.resolve(JSON.stringify(this.savePointer()));
    }
    if (action === 'ndkPointerRestore') {
      return Promise.resolve(JSON.stringify(this.restorePointer()));
    }
    if (action === 'ndkFunctionKeyState') {
      return this.ndkResult(NativeInput.getFunctionKeyState(args['keyCode'] as number));
    }
    if (action === 'ndkMaxTouchPoints') {
      return this.ndkResult(NativeInput.queryMaxTouchPoints());
    }
    if (action === 'ndkCursorLock') {
      return this.ndkResult(NativeInput.lockCursor(args['windowId'] as number,
        (args['followMovement'] as boolean) ?? true));
    }
    if (action === 'ndkCursorUnlock') {
      return this.ndkResult(NativeInput.unlockCursor(args['windowId'] as number));
    }
    // ===== NDK v2 能力（napi_extras.cpp；session-43e17adf 追加，勿动）=====
    if (action === 'ndkIntervalSinceInput') {
      const ms: number = NativeInput.getIntervalSinceLastInput();
      return Promise.resolve(JSON.stringify({ ok: ms >= 0, ms: ms }));
    }
    if (action === 'ndkSetPointerStyle') {
      return this.ndkResult(NativeInput.setPointerStyle(args['windowId'] as number, args['style'] as number));
    }
    if (action === 'ndkGetPointerStyle') {
      return this.ndkResult(NativeInput.getPointerStyle(args['windowId'] as number));
    }
    if (action === 'ndkSetPointerVisible') {
      const visible: boolean = args['visible'] !== false;
      return this.ndkResult(NativeInput.setPointerVisible(visible));
    }
    if (action === 'ndkMouseWatch') {
      return this.ndkMouseWatch(args);
    }
    if (action === 'ndkTouchWatch') {
      return this.ndkTouchWatch(args);
    }
    if (action === 'ndkAxisWatch') {
      return this.ndkAxisWatch(args);
    }
    if (action === 'ndkMonitorWhileRecording') {
      return this.ndkMonitorWhileRecording(args);
    }
    if (action === 'ndkTraceBegin') {
      return this.ndkResult(NativeInput.traceBegin(this.stringArg(args, 'name')));
    }
    if (action === 'ndkTraceEnd') {
      return this.ndkResult(NativeInput.traceEnd());
    }
    if (action === 'ndkScreenshot') {
      return this.ndkScreenshot(args);
    }
    // ===== NDK v3：窗口信息与按窗/整屏截图（napi_extras_v3.cpp）=====
    if (action === 'ndkMainWindows') {
      return this.ndkMainWindows();
    }
    if (action === 'ndkDisplayCapture') {
      return this.ndkDisplayCapture(args);
    }
    if (action === 'ndkWindowSnapshot') {
      return this.ndkWindowSnapshot(args);
    }
    if (action === 'ndkProbeChildProcess') {
      return Promise.resolve(JSON.stringify(NativeInput.probeNativeChildProcess()));
    }
    // 无障碍服务自检：系统是否认得我们的 accessibility 扩展、总开关是否打开
    // 注意：action 名不能以 "a11y" 开头——bridge-server 会按该前缀把它路由到无障碍通道。
    if (action === 'accessibilityStatus') {
      return this.a11yStatus();
    }
    if (action === 'watchProbe') {
      return this.watchProbe(args);
    }
    if (action === 'getWindowLayouts') {
      return this.getWindowLayouts(args);
    }
    if (action === 'listMainWindows') {
      return this.listMainWindows();
    }
    if (action === 'snapshotWindow') {
      return this.snapshotWindow(args);
    }
    if (action === 'getGlobalWindowMode') {
      return this.getGlobalWindowMode(args);
    }
    if (action === 'getSelfWindowInfo') {
      return this.getSelfWindowInfo();
    }
    if (action === 'moveSelfWindow') {
      return this.moveSelfWindow(args);
    }
    if (action === 'resizeSelfWindow') {
      return this.resizeSelfWindow(args);
    }
    if (action === 'setSelfWindowMode') {
      return this.setSelfWindowMode(args);
    }
    if (action === 'listDisplays') {
      return this.listDisplays();
    }
    if (action === 'requestScreenCapture') {
      return this.requestScreenCapture();
    }
    if (action === 'fetchFile') {
      return this.fetchFile(args);
    }
    if (action === 'ocrImage') {
      return this.ocrImage(args);
    }
    if (action === 'statusBarAdd') {
      return this.statusBarAdd(args);
    }
    if (action === 'statusBarRemove') {
      return this.statusBarRemove();
    }
    if (action === 'statusBarStatus') {
      return this.statusBarStatus();
    }
    if (action === 'quickBarAdd') {
      return this.quickBarAdd(args);
    }
    if (action === 'quickBarList') {
      return this.quickBarList();
    }
    if (action === 'quickBarStatus') {
      return this.quickBarStatus();
    }
    if (action === 'quickBarProgress') {
      return this.quickBarProgress(args);
    }
    if (action === 'localChat') {
      return this.localChat(args);
    }
    if (action === 'nlpEntity') {
      return this.nlpEntity(args);
    }
    if (action === 'nlpSegment') {
      return this.nlpSegment(args);
    }
    if (action === 'ttsSpeak') {
      return this.ttsSpeak(args);
    }
    if (action === 'embedText') {
      return this.embedText(args);
    }
    if (action === 'embedBatch') {
      return this.embedBatch(args);
    }
    if (action === 'splitText') {
      return this.splitText(args);
    }
    if (action === 'kvOpen') {
      return this.kvOpen(args);
    }
    if (action === 'kvPut') {
      return this.kvPut(args);
    }
    if (action === 'kvGet') {
      return this.kvGet(args);
    }
    if (action === 'kvList') {
      return this.kvList(args);
    }
    if (action === 'kvSync') {
      return this.kvSync(args);
    }
    if (action === 'wsServerStart') {
      return this.wsServerStart(args);
    }
    if (action === 'wsServerStop') {
      return this.wsServerStop();
    }
    if (action === 'wsServerSend') {
      return this.wsServerSend(args);
    }
    if (action === 'wsServerStatus') {
      return this.wsServerStatus();
    }
    if (action === 'shareShow') {
      return this.shareShow(args);
    }
    if (action === 'acsCreate') {
      return this.acsCreate(args);
    }
    if (action === 'acsConnect') {
      return this.acsConnect(args);
    }
    if (action === 'acsSend') {
      return this.acsSend(args);
    }
    if (action === 'acsDestroy') {
      return this.acsDestroy(args);
    }
    if (action === 'acsStatus') {
      return this.acsStatus();
    }
    if (action === 'getPermissionStatus') {
      return this.getPermissionStatus();
    }
    if (action === 'requestPermissions') {
      return this.requestPermissions();
    }
    if (action === 'calendarQuery') {
      return this.calendarQuery(args);
    }
    if (action === 'commonEventProbe') {
      return this.commonEventProbe(args);
    }
    if (action === 'startContinuousTask') {
      return this.startContinuousTask(args);
    }
    if (action === 'stopContinuousTask') {
      return this.stopContinuousTask();
    }
    if (action === 'resolveAbilityByUri') {
      return this.resolveAbilityByUri(args);
    }
    if (action === 'getAllBundleInfo') {
      return this.getAllBundleInfo();
    }
    if (action === 'watchEvents') {
      return this.watchEvents(args);
    }
    if (action === 'publishReminder') {
      return this.publishReminder(args);
    }
    if (action === 'cancelReminder') {
      return this.cancelReminder(args);
    }
    if (action === 'listDistributedDevices') {
      return this.listDistributedDevices();
    }
    if (action === 'devicePerception') {
      return this.devicePerception(args);
    }
    if (action === 'usbDevices') {
      return this.usbDevices();
    }
    if (action === 'thermalLevel') {
      return this.thermalLevel();
    }
    if (action === 'scheduleWork') {
      return this.scheduleWork(args);
    }
    if (action === 'listWorks') {
      return this.listWorks();
    }
    if (action === 'udmfShare') {
      return this.udmfShare(args);
    }
    if (action === 'udmfQuery') {
      return this.udmfQuery(args);
    }
    if (action === 'dsoStart') {
      return this.dsoStart(args);
    }
    if (action === 'dsoStop') {
      return this.dsoStop();
    }
    if (action === 'dsoWrite') {
      return this.dsoWrite(args);
    }
    if (action === 'dsoRead') {
      return this.dsoRead();
    }
    if (action === 'dsoStatus') {
      return this.dsoStatus();
    }
    if (action === 'collabProbe') {
      return this.collabProbe(args);
    }
    if (action === 'collabNotify') {
      return this.collabNotify(args);
    }
    return Promise.reject(new Error('unsupported action: ' + action));
  }

  /**
   * The 垂类应用选择框 (Intent Panel) entry point.
   *
   * `args.type` is one of navigation | mail | finance | flight | express and
   * `args.wantParam` carries the business parameters documented per type.
   */
  private startAbilityByType(args: Record<string, Object>): Promise<string> {
    const type = this.stringArg(args, 'type');
    if (type.length === 0) {
      return Promise.reject(
        new Error('startAbilityByType: "type" is required (navigation|mail|finance|flight|express)')
      );
    }
    const wantParam = this.buildWantParam(type, args);
    return new Promise<string>((resolve, reject) => {
      const callback: common.AbilityStartCallback = {
        onError: (code: number, name: string, message: string) => {
          reject(new Error('startAbilityByType failed, code=' + code.toString() +
            ', name=' + name + ', message=' + message));
        },
        onResult: (abilityResult: common.AbilityResult) => {
          // The panel hands control to the target app; there is nothing to
          // report back beyond "it started", so we deliberately do not read
          // fields off abilityResult here.
          resolve('{"started":true}');
        }
      };
      this.abilityContext.startAbilityByType(type, wantParam, callback, (err) => {
        if (err) {
          reject(new Error('startAbilityByType failed: ' + this.text(err)));
        } else {
          resolve('{"started":true}');
        }
      });
    });
  }

  /**
   * Builds the wantParam map for `startAbilityByType`.
   *
   * Huawei documents that the mail panel wants every string / string[] value
   * percent-encoded by the caller (mailto documents the same), while the
   * navigation panel takes raw values. Callers therefore pass plain text and we
   * apply the per-type encoding rule here, exactly once.
   */
  private buildWantParam(type: string, args: Record<string, Object>): Record<string, Object> {
    const out: Record<string, Object> = {};
    const raw = args['wantParam'];
    if (raw !== undefined && raw !== null) {
      const source = raw as Record<string, Object>;
      const keys = Object.keys(source);
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i];
        const value = source[key];
        out[key] = type === 'mail' ? this.encodeValue(value) : value;
      }
    }
    if (out['sceneType'] === undefined) {
      out['sceneType'] = 1;
    }
    return out;
  }

  private encodeValue(value: Object): Object {
    if (typeof value === 'string') {
      return encodeURI(value as string);
    }
    if (Array.isArray(value)) {
      const items = value as Object[];
      const encoded: Object[] = [];
      for (let i = 0; i < items.length; i++) {
        const item = items[i];
        encoded.push(typeof item === 'string' ? encodeURI(item as string) : item);
      }
      return encoded;
    }
    return value;
  }

  /**
   * Generic `startAbility`. This is the route the `aa` CLI cannot express:
   * it can attach `flags` (e.g. FLAG_AUTH_READ_URI_PERMISSION = 0x1) so the
   * target app is actually allowed to read the file we hand it.
   */
  private async startAbility(args: Record<string, Object>): Promise<string> {
    const want: Want = {};
    const action = this.stringArg(args, 'action');
    if (action.length > 0) {
      want.action = action;
    }
    const uri = this.stringArg(args, 'uri');
    if (uri.length > 0) {
      want.uri = uri;
    }
    const type = this.stringArg(args, 'type');
    if (type.length > 0) {
      want.type = type;
    }
    const bundleName = this.stringArg(args, 'bundleName');
    if (bundleName.length > 0) {
      want.bundleName = bundleName;
    }
    const abilityName = this.stringArg(args, 'abilityName');
    if (abilityName.length > 0) {
      want.abilityName = abilityName;
    }
    const moduleName = this.stringArg(args, 'moduleName');
    if (moduleName.length > 0) {
      want.moduleName = moduleName;
    }
    const entities = args['entities'];
    if (Array.isArray(entities)) {
      want.entities = entities as string[];
    }
    const parameters = args['parameters'];
    if (parameters !== undefined && parameters !== null) {
      want.parameters = parameters as Record<string, Object>;
    }
    const flags = args['flags'];
    if (typeof flags === 'number') {
      want.flags = flags as number;
    }

    if (want.bundleName === undefined && want.action === undefined && want.uri === undefined) {
      throw new Error('startAbility: at least one of bundleName / action / uri is required');
    }
    try {
      await this.abilityContext.startAbility(want);
      return '{"started":true}';
    } catch (err) {
      throw new Error('startAbility failed: ' + this.text(err));
    }
  }

  private async openLink(args: Record<string, Object>): Promise<string> {
    const url = this.stringArg(args, 'url');
    if (url.length === 0) {
      throw new Error('openLink: "url" is required');
    }
    try {
      await this.abilityContext.openLink(url);
      return '{"opened":true}';
    } catch (err) {
      throw new Error('openLink failed: ' + this.text(err));
    }
  }

  /**
   * Publishes a system notification — the native equivalent of the IM-side
   * "task finished" ping, but shown by the OS itself.
   *
   * args: { title, text, longText?, id? }
   *   - longText: switches to the long-text layout (title/text still required)
   *   - id: pass a stable id to update a previous notification in place
   *         instead of stacking a new one (handy for progress updates)
   *
   * Tapping the notification reopens the DshDesktop window.
   */
  private async notify(args: Record<string, Object>): Promise<string> {
    const title = this.stringArg(args, 'title');
    const text = this.stringArg(args, 'text');
    if (title.length === 0 || text.length === 0) {
      throw new Error('notify: "title" and "text" are required');
    }
    const longText = this.stringArg(args, 'longText');
    const id = this.notificationId(args);

    const enabled = await this.ensureNotificationsEnabled();
    if (!enabled) {
      throw new Error('notify: system notifications are disabled for this app ' +
        '(the OS prompt was declined, or notifications are off in Settings)');
    }
    const agent = await this.buildNotificationWantAgent(id);
    const buttons = await this.buildNotificationButtons(args, id);
    if (buttons.length > 0) {
      // Arm the callback path before publishing, so a press landing immediately
      // after publish cannot be missed.
      await this.subscribeNotificationActions();
    }

    if (longText.length > 0) {
      const longRequest: notificationManager.NotificationRequest = {
        id: id,
        slotType: 1,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_LONG_TEXT,
          longText: {
            title: title,
            text: text,
            longText: longText,
            briefText: text,
            expandedTitle: title
          }
        },
        wantAgent: agent,
        actionButtons: buttons
      };
      await notificationManager.publish(longRequest);
    } else {
      const basicRequest: notificationManager.NotificationRequest = {
        id: id,
        slotType: 1,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: text
          }
        },
        wantAgent: agent,
        actionButtons: buttons
      };
      await notificationManager.publish(basicRequest);
    }
    hilog.info(DOMAIN, TAG, 'notification published id=%{public}d buttons=%{public}d',
      id, buttons.length);
    return '{"published":true,"id":' + id.toString() + ',"buttons":' + buttons.length.toString() + '}';
  }

  /** Removes a notification previously published through `notify`. */
  private async dismissNotification(args: Record<string, Object>): Promise<string> {
    const id = this.numberArg(args, 'id');
    if (id <= 0) {
      throw new Error('dismissNotification: a positive "id" is required');
    }
    await notificationManager.cancel(id);
    return '{"dismissed":true,"id":' + id.toString() + '}';
  }

  /**
   * Write text to the system pasteboard (L0 通路).
   *
   * Why this exists: filling long / CJK text into another app's field via
   * `uitest uiInput inputText` is fragile (shell quoting, length limits),
   * while the app process may write the clipboard natively. Pair this with
   * a single Ctrl+V keyEvent injection (uitest uiInput keyEvent 29 47) after
   * focusing the target field.
   */
  private async setClipboard(args: Record<string, Object>): Promise<string> {
    const text = this.stringArg(args, 'text');
    if (text.length === 0) {
      return Promise.reject(new Error('setClipboard: "text" is required'));
    }
    const data: pasteboard.PasteData = pasteboard.createData('text/plain', text);
    await pasteboard.getSystemPasteboard().setData(data);
    hilog.info(DOMAIN, TAG, 'setClipboard: wrote %{public}d chars', text.length);
    const len = text.length;
    return '{"ok":true,"chars":' + len.toString() + '}';
  }

  /**
   * Read the system pasteboard back (diagnostic companion of setClipboard).
   *
   * KNOWN PLATFORM LIMIT (measured 2026-10-10): reading another app's clip
   * requires ohos.permission.READ_PASTEBOARD, which is availableLevel
   * system_basic (provisionEnable=true, so it is ACL-able but needs a
   * re-issued debug profile). With this app's current profile (apl=normal,
   * allowed-acls=[]) hasData() reports true while getMimeTypes()/getRecordCount()
   * come back empty — i.e. the clip is invisible, not absent. So treat an empty
   * result here as "not permitted", and use `testhelper get-pastedata` over hdc
   * for a ground-truth read. Writing (setClipboard) needs no permission at all.
   */
  private async getClipboard(): Promise<string> {
    const pb = pasteboard.getSystemPasteboard();
    const has = await pb.hasData();
    if (!has) {
      return '{"hasData":false}';
    }
    const data: pasteboard.PasteData = await pb.getData();
    // getPrimaryText() reads record 0; when the clip was written with a
    // non-text MIME the plain-text getter yields "" even though the pasteboard
    // is non-empty, so fall back to reading the first record explicitly and
    // report the type/record count to make that distinguishable from "empty".
    // Defensive: getMimeTypes()/getRecordCount() can be undefined on this
    // platform, so every accessor is guarded rather than trusted.
    let text: string = data.getPrimaryText();
    if (text === undefined || text === null) {
      text = '';
    }
    if (text.length === 0) {
      const mimes: Array<string> | undefined = data.getMimeTypes();
      const countRaw: number | undefined = data.getRecordCount();
      const count = (countRaw !== undefined && countRaw !== null) ? countRaw : 0;
      if (count > 0) {
        const rec: pasteboard.PasteDataRecord = data.getRecordAt(0);
        const recText: string = rec.toPlainText();
        if (recText !== undefined && recText !== null && recText.length > 0) {
          text = recText;
        }
      }
      const mimeCount = (mimes !== undefined && mimes !== null) ? mimes.length : 0;
      const preview0 = text.slice(0, 80);
      return '{"hasData":true' +
        ',"mimeTypes":' + mimeCount.toString() +
        ',"records":' + count.toString() +
        ',"length":' + text.length.toString() +
        ',"truncated":' + (text.length > preview0.length ? 'true' : 'false') +
        ',"text":"' + this.esc(preview0) + '"}';
    }
    const preview = text.slice(0, 80);
    return '{"hasData":true' +
      ',"length":' + text.length.toString() +
      ',"truncated":' + (text.length > preview.length ? 'true' : 'false') +
      ',"text":"' + this.esc(preview) + '"}';
  }

  /**
   * Volume read/write (2026-10-12, knowledge/14 #2): AudioManager set/getVolume
   * need ACCESS_NOTIFICATION_POLICY (normal, already declared). Not affected by
   * the trial profile expiry. args: {op:'get'|'set', type?:'MEDIA'|..., volume?:int}
   */
  private async volume(args: Record<string, Object>): Promise<string> {
    const am = audio.getAudioManager();
    const typeName: string = this.stringArg(args, 'type') || 'MEDIA';
    let vt: audio.AudioVolumeType;
    switch (typeName) {
      case 'VOICE_CALL': vt = audio.AudioVolumeType.VOICE_CALL; break;
      case 'RINGTONE': vt = audio.AudioVolumeType.RINGTONE; break;
      case 'ALARM': vt = audio.AudioVolumeType.ALARM; break;
      case 'ACCESSIBILITY': vt = audio.AudioVolumeType.ACCESSIBILITY; break;
      case 'VOICE_ASSISTANT': vt = audio.AudioVolumeType.VOICE_ASSISTANT; break;
      case 'MEDIA': vt = audio.AudioVolumeType.MEDIA; break;
      default: throw new Error('volume: unknown type "' + typeName + '"');
    }
    const op: string = this.stringArg(args, 'op') || 'get';
    if (op === 'set') {
      const v: number = this.numberArg(args, 'volume');
      const maxV: number = await am.getMaxVolume(vt);
      if (v < 0 || v > maxV) {
        throw new Error('volume: value ' + v.toString() + ' out of range 0..' + maxV.toString());
      }
      await am.setVolume(vt, v);
    }
    const cur: number = await am.getVolume(vt);
    const max: number = await am.getMaxVolume(vt);
    const min: number = await am.getMinVolume(vt);
    return '{"type":"' + typeName + '","volume":' + cur.toString() +
      ',"min":' + min.toString() + ',"max":' + max.toString() + '}';
  }

  /**
   * Kill another app's processes (2026-10-12, knowledge/14 #3): needs
   * CLEAN_BACKGROUND_PROCESSES (normal, already declared).
   * args: {bundleName, clearPageStack?:bool}
   */
  private async killProcess(args: Record<string, Object>): Promise<string> {
    const bundle: string = this.stringArg(args, 'bundleName');
    if (bundle.length === 0) {
      throw new Error('killProcess: "bundleName" is required');
    }
    if (bundle === this.abilityContext.abilityInfo.bundleName) {
      throw new Error('killProcess: refusing to kill self');
    }
    const clearStack: boolean = args['clearPageStack'] === true;
    await appManager.killProcessesByBundleName(bundle, clearStack);
    return '{"killed":"' + this.esc(bundle) + '","clearPageStack":' + (clearStack ? 'true' : 'false') + '}';
  }

  /**
   * knowledge/14 #5: cross-app window list + geometry + z-order via
   * window.getAllWindowLayoutInfo (API 26, NO permission). The CGWindowList /
   * EnumWindows counterpart. args: {displayId?, excludeSystemWindows?}
   */
  private async windowLayoutAll(args: Record<string, Object>): Promise<string> {
    const didRaw = this.numberArg(args, 'displayId');
    const did: number = didRaw >= 0 ? didRaw : 0;
    const opt: window.WindowInfoOptions = {};
    if (args['excludeSystemWindows'] === true) {
      opt.excludeSystemWindows = true;
    }
    const list = await window.getAllWindowLayoutInfo(did, opt);
    let out: string = '{"count":' + list.length.toString() + ',"windows":[';
    let first = true;
    for (const w of list) {
      const r = w.windowRect;
      const alpha: number = w.windowAlpha !== undefined ? w.windowAlpha : -1;
      out += (first ? '' : ',') + '{"rect":[' + r.left.toString() + ',' + r.top.toString() +
        ',' + r.width.toString() + ',' + r.height.toString() + '],"alpha":' + alpha.toString() + '}';
      first = false;
    }
    return out + ']}';
  }

  /**
   * knowledge/14 #8a: clipboard change notification. pasteboard.on('update')
   * (no permission to WATCH; READ_PASTEBOARD only needed to read content).
   * Events are pushed to the node side as type 'clipboard_update'.
   * args: {enable:bool}
   */
  private clipboardWatch(args: Record<string, Object>): Promise<string> {
    const pb = pasteboard.getSystemPasteboard();
    const enable: boolean = args['enable'] !== false;
    if (enable) {
      if (this.clipboardWatchCb !== undefined) {
        return Promise.resolve('{"watching":true,"note":"already"}');
      }
      const cb = (): void => {
        this.postEvent('clipboard_update', '{}');
      };
      pb.on('update', cb);
      this.clipboardWatchCb = cb;
      return Promise.resolve('{"watching":true}');
    }
    if (this.clipboardWatchCb !== undefined) {
      pb.off('update', this.clipboardWatchCb);
      this.clipboardWatchCb = undefined;
    }
    return Promise.resolve('{"watching":false}');
  }

  /**
   * knowledge/14 #8b: rich clipboard — mime types + per-type content preview.
   * Needs READ_PASTEBOARD (trial ACL, granted).
   */
  private async clipboardRich(): Promise<string> {
    const pb = pasteboard.getSystemPasteboard();
    const has = await pb.hasData();
    if (!has) {
      return '{"hasData":false}';
    }
    const data: pasteboard.PasteData = await pb.getData();
    const mimes: Array<string> = data.getMimeTypes();
    let out: string = '{"hasData":true,"mimeTypes":[';
    for (let i = 0; i < mimes.length; i++) {
      out += (i === 0 ? '' : ',') + '"' + this.esc(mimes[i]) + '"';
    }
    out += ']';
    const count: number = data.getRecordCount();
    out += ',"records":' + count.toString();
    if (count > 0) {
      const rec: pasteboard.PasteDataRecord = data.getRecordAt(0);
      out += ',"plainText":"' + this.esc(rec.toPlainText().slice(0, 60)) + '"';
      const html: string = rec.htmlText;
      out += ',"hasHtml":' + (html !== undefined && html.length > 0 ? 'true' : 'false');
      const uri: string = rec.uri;
      out += ',"hasUri":' + (uri !== undefined && uri.length > 0 ? 'true' : 'false');
      out += ',"hasWant":' + (rec.want !== undefined ? 'true' : 'false');
    }
    return out + '}';
  }

  /**
   * knowledge/14 #6: register an app-global hotkey (inputConsumer, API 14,
   * NO permission). Fires as 'hotkey' events on the node side. System-occupied
   * combos fail with 4200002, already-subscribed with 4200003.
   * args: {preKeys:[num], finalKey:num, enable?:bool}
   */
  private hotkeyWatch(args: Record<string, Object>): Promise<string> {
    const enable: boolean = args['enable'] !== false;
    if (!enable) {
      if (this.hotkeyWatchCb !== undefined && this.hotkeyWatchOpts !== undefined) {
        inputConsumer.off('hotkeyChange', this.hotkeyWatchOpts, this.hotkeyWatchCb);
        this.hotkeyWatchCb = undefined;
        this.hotkeyWatchOpts = undefined;
      }
      return Promise.resolve('{"watching":false}');
    }
    const pre: Array<number> = args['preKeys'] as Array<number>;
    const fin: number = this.numberArg(args, 'finalKey');
    if (pre === undefined || fin <= 0) {
      throw new Error('hotkeyWatch: need preKeys:[num,...] and finalKey:num (HarmonyOS KeyCode)');
    }
    const opts: inputConsumer.HotkeyOptions = { preKeys: pre, finalKey: fin, isRepeat: false };
    const cb: Callback<inputConsumer.HotkeyOptions> = (hk: inputConsumer.HotkeyOptions) => {
      this.postEvent('hotkey', '{"finalKey":' + hk.finalKey.toString() + '}');
    };
    try {
      inputConsumer.on('hotkeyChange', opts, cb);
      this.hotkeyWatchCb = cb;
      this.hotkeyWatchOpts = opts;
      return Promise.resolve('{"watching":true,"finalKey":' + fin.toString() + '}');
    } catch (e) {
      const m = e instanceof Error ? e.message : String(e);
      return Promise.resolve('{"watching":false,"error":"' + this.esc(m.slice(0, 120)) + '"}');
    }
  }

  /**
   * knowledge/14 #7: inotify-style file watcher via fileIo.createWatcher
   * (no permission; NOT recursive). Events arrive as 'fs_event' on node side.
   * events bitmask uses inotify values (CREATE 0x100 / DELETE 0x200 /
   * MODIFY 0x2 / MOVED_FROM 0x40 / MOVED_TO 0x80 / ATTRIB 0x4).
   * args: {path, events?:number, enable?:bool}
   */
  private fsWatch(args: Record<string, Object>): Promise<string> {
    const enable: boolean = args['enable'] !== false;
    if (!enable) {
      if (this.fsWatcher !== undefined) {
        this.fsWatcher.stop();
        this.fsWatcher = undefined;
      }
      return Promise.resolve('{"watching":false}');
    }
    const path: string = this.stringArg(args, 'path');
    if (path.length === 0) {
      throw new Error('fsWatch: "path" is required');
    }
    const evRaw = this.numberArg(args, 'events');
    const events: number = evRaw > 0 ? evRaw : 0x3C6;
    const listener: WatchEventListener = (ev: WatchEvent) => {
      this.postEvent('fs_event', '{"fileName":"' + this.esc(ev.fileName) +
        '","event":' + ev.event.toString() + '}');
    };
    try {
      if (this.fsWatcher !== undefined) {
        this.fsWatcher.stop();
      }
      this.fsWatcher = fileIo.createWatcher(path, events, listener);
      this.fsWatcher.start();
      return Promise.resolve('{"watching":true,"path":"' + this.esc(path) + '"}');
    } catch (e) {
      const m = e instanceof Error ? e.message : String(e);
      return Promise.resolve('{"watching":false,"error":"' + this.esc(m.slice(0, 120)) + '"}');
    }
  }

  /**
   * knowledge/14 #13: print files via the system print service
   * (@ohos.print, no permission). Opens the system print UI/preview.
   * args: {path} — absolute file path readable by this app.
   */
  private async printFile(args: Record<string, Object>): Promise<string> {
    const path: string = this.stringArg(args, 'path');
    if (path.length === 0) {
      throw new Error('printFile: "path" is required');
    }
    try {
      const task = await print.print([path], this.abilityContext);
      task.on('succeed', () => { this.postEvent('print_done', '{"state":"succeed"}'); });
      task.on('block', () => { this.postEvent('print_done', '{"state":"blocked"}'); });
      return '{"printed":true,"note":"system print UI shown; events arrive as print_done"}';
    } catch (e) {
      const m = e instanceof Error ? e.message : String(e);
      return '{"printed":false,"error":"' + this.esc(m.slice(0, 120)) + '"}';
    }
  }

  /**
   * CC msg-71 C: offscreen/headless UI render. NOTE: module-level
   * componentSnapshot.createFromBuilder crashes in a plain agent context
   * (observeComponentCreation2 undefined) — must go through the window's
   * UIContext.getComponentSnapshot(). args: {text?} → PNG in filesDir.
   */
  private async offscreenRender(args: Record<string, Object>): Promise<string> {
    // v4（2026-10-12）：改走 NDK native_drawing 离屏渲染。
    // 旧实现用 componentSnapshot.createFromBuilder，在非组件宿主上下文必炸
    // （Cannot read property observeComponentCreation2 of undefined），已废弃。
    const text: string = this.stringArg(args, 'text') || 'DSH offscreen render';
    const subtitle: string = this.stringArg(args, 'subtitle') || new Date().toLocaleString();
    const width: number = args['width'] === undefined ? 720 : this.numberArg(args, 'width');
    const height: number = args['height'] === undefined ? 320 : this.numberArg(args, 'height');
    const path: string = this.abilityContext.filesDir + '/offscreen-' + Date.now().toString() + '.png';
    const file = fileIo.openSync(path,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    let code = -1;
    let outW = width;
    let outH = height;
    try {
      const r: RenderCardResult = NativeInput.renderCardToFd(file.fd, width, height, text, subtitle, 0);
      code = r.code;
      outW = r.width;
      outH = r.height;
    } finally {
      fileIo.closeSync(file);
    }
    if (code !== 0) {
      return '{"ok":false,"code":' + code.toString() + ',"via":"native_drawing"}';
    }
    const st: fileIo.Stat = fileIo.statSync(path);
    return '{"ok":true,"bytes":' + st.size.toString() + ',"width":' + outW.toString() +
      ',"height":' + outH.toString() + ',"path":"' + this.esc(path) + '","via":"native_drawing"}';
  }

  /**
   * knowledge/14 #7 + CC msg-71: zero-permission device status snapshot
   * (battery / network bearer / input idle).
   */
  private async deviceStatus(): Promise<string> {
    let out: string = '{"batterySOC":' + batteryInfo.batterySOC.toString();
    out += ',"charging":' + (batteryInfo.chargingStatus !== batteryInfo.BatteryChargeState.NONE ? 'true' : 'false');
    try {
      const net = await connection.getDefaultNet();
      const caps = await connection.getNetCapabilities(net);
      let types: string = '';
      for (const b of caps.bearerTypes) {
        types += (types.length > 0 ? ',' : '') + b.toString();
      }
      out += ',"netBearers":"' + types + '"';
    } catch { out += ',"netBearers":"unknown"'; }
    try {
      const idle: number = await inputDevice.getIntervalSinceLastInput();
      out += ',"idleMs":' + idle.toString();
    } catch { /* ignore */ }
    return out + '}';
  }

  /**
   * CC msg-70 #15: pointer visibility (录屏/演示时隐藏光标), no permission.
   * args: {show:bool}
   */
  private async pointerVisible(args: Record<string, Object>): Promise<string> {
    const show: boolean = args['show'] !== false;
    await pointer.setPointerVisible(show);
    return '{"pointerVisible":' + (show ? 'true' : 'false') + '}';
  }

  // ===== NDK-only 辅助（session-98608bdc 追加）=====

  /** 把 NativeResult 包装成 dispatch 约定的 JSON 字符串 */
  private ndkResult(r: Object): Promise<string> {
    return Promise.resolve(JSON.stringify(r));
  }

  /**
   * 无障碍自检（判「设置里为什么没有我们的服务」的权威 oracle）。
   * - masterOpen：无障碍总开关（关着时「已安装的服务」可能为空/不可用）
   * - installed：系统登记为已安装的无障碍扩展（含本应用则声明 OK）
   * - enabled：当前已启用的服务
   */
  private a11yStatus(): Promise<string> {
    let masterOpen = false;
    let installed: accessibility.AccessibilityAbilityInfo[] = [];
    let enabled: accessibility.AccessibilityAbilityInfo[] = [];
    let err = '';
    try {
      masterOpen = accessibility.isOpenAccessibilitySync();
    } catch (e) {
      err = 'isOpenAccessibilitySync: ' + this.text(e);
    }
    try {
      installed = accessibility.getAccessibilityExtensionListSync('all', 'install');
    } catch (e) {
      err = err + ' | install: ' + this.text(e);
    }
    try {
      enabled = accessibility.getAccessibilityExtensionListSync('all', 'enable');
    } catch (e) {
      err = err + ' | enable: ' + this.text(e);
    }
    return Promise.resolve('{"masterOpen":' + (masterOpen ? 'true' : 'false') +
      ',"installedCount":' + installed.length.toString() +
      ',"enabledCount":' + enabled.length.toString() +
      ',"installed":' + JSON.stringify(installed) +
      ',"enabled":' + JSON.stringify(enabled) +
      ',"error":' + JSON.stringify(err) + '}');
  }

  /**
   * NDK 鼠标注入（免 ACL，需先 ndkRequestInjection 授权一次）。
   * args: {op:'move'|'button'|'axis', x, y, button?, down?, axisType?, axisValue?}
   */
  // ===== v5：注入类操作的「空闲闸 + 鼠标位置还原」 =====
  // 目标：用户正在用电脑时不插队（闸），动完把鼠标放回原处（还原）。
  // 闸参数（三个注入 action 通用）：idleMs 默认 1200（要求至少空闲这么久）、waitMs 默认 0（等待上限）、force=true 跳过闸。
  // 返回码：0=通过；-7=用户忙未注入（user_busy）。
  private savedPointerX: number = -1;
  private savedPointerY: number = -1;

  /** 空闲闸：返回 0=可注入；-7=用户忙 */
  private async injectionGate(args: Record<string, Object>): Promise<number> {
    if (args['force'] === true) {
      return 0;
    }
    const idleMs: number = args['idleMs'] === undefined ? 1200 : this.numberArg(args, 'idleMs');
    const waitMs: number = args['waitMs'] === undefined ? 0 : this.numberArg(args, 'waitMs');
    const deadline: number = Date.now() + waitMs;
    while (true) {
      const since: number = NativeInput.getIntervalSinceLastInput();
      if (since < 0) {
        return 0;   // 读不到（INTERCEPT 未授）→ 不拦，交调用方决定
      }
      if (since >= idleMs) {
        return 0;
      }
      if (Date.now() >= deadline) {
        return -7;
      }
      await this.sleep(200);
    }
  }

  /**
   * DDK 设备枚举（触控板驱动第一步）：列出外接 USB HID 设备。
   * 需要 ACCESS_EXTENSIONAL_DEVICE_DRIVER（normal，声明即得）。
   * 用途：确认 Magic Trackpad 是否出现在 DDK 视野内（决定能否写驱动）。
   */
  private driverDevices(): string {
    try {
      const devs = deviceManager.queryDevices(deviceManager.BusType.USB);
      let arr = '[';
      for (let i = 0; i < devs.length; i++) {
        const d = devs[i];
        arr += (i > 0 ? ',' : '') + '{"deviceId":' + d.deviceId.toString() +
          ',"busType":' + d.busType.toString() +
          ',"description":"' + this.esc(d.description) + '"}';
      }
      return '{"ok":true,"count":' + devs.length.toString() + ',"devices":' + arr + ']}';
    } catch (e) {
      return '{"ok":false,"error":"' + this.esc(this.text(e)) + '"}';
    }
  }

  /** 记下当前鼠标位置（供 ndkPointerRestore 用） */
  private savePointer(): PointerOpResult {
    const p = NativeInput.getPointerLocation();
    this.savedPointerX = p.x;
    this.savedPointerY = p.y;
    const out: PointerOpResult = { ok: p.ok, code: p.code, x: p.x, y: p.y, reason: '' };
    return out;
  }

  /** 把鼠标移回最近一次 ndkPointerSave 的位置 */
  private restorePointer(): PointerOpResult {
    if (this.savedPointerX < 0 || this.savedPointerY < 0) {
      const miss: PointerOpResult = { ok: false, code: -8, x: -1, y: -1, reason: 'no_saved_pointer' };
      return miss;
    }
    const r = NativeInput.injectMouseMove(Math.round(this.savedPointerX), Math.round(this.savedPointerY));
    const done: PointerOpResult = { ok: r.ok, code: r.code, x: this.savedPointerX, y: this.savedPointerY, reason: '' };
    return done;
  }

  private async ndkInjectKey(args: Record<string, Object>): Promise<string> {
    const gate: number = await this.injectionGate(args);
    if (gate !== 0) {
      const busy: InjectionGateResult = { ok: false, code: gate, reason: 'user_busy' };
      return JSON.stringify(busy);
    }
    return this.ndkResult(NativeInput.injectKey(args['keyCode'] as number, args['action'] as number));
  }

  private async ndkInjectTouch(args: Record<string, Object>): Promise<string> {
    const gate: number = await this.injectionGate(args);
    if (gate !== 0) {
      const busy: InjectionGateResult = { ok: false, code: gate, reason: 'user_busy' };
      return JSON.stringify(busy);
    }
    return this.ndkResult(NativeInput.injectTouch(args['action'] as number, args['x'] as number,
      args['y'] as number, (args['fingerId'] as number) ?? 0));
  }

  /**
   * 鼠标注入（带闸）。
   * args: {op:'move'|'button'|'axis', x, y, button?, down?, axisType?, axisValue?,
   *        restore?:boolean, idleMs?, waitMs?, force?}
   * restore=true → 动完把鼠标移回操作前的位置（单次点击场景推荐）。
   * 多步序列（拖拽 down→move→up）不要逐步 restore，改用 ndkPointerSave / ndkPointerRestore 包住整段。
   */
  private async ndkInjectMouse(args: Record<string, Object>): Promise<string> {
    const op: string = this.stringArg(args, 'op');
    const x: number = this.numberArg(args, 'x');
    const y: number = this.numberArg(args, 'y');
    const gate: number = await this.injectionGate(args);
    if (gate !== 0) {
      const busy: InjectionGateResult = { ok: false, code: gate, reason: 'user_busy' };
      return JSON.stringify(busy);
    }
    const restore: boolean = args['restore'] === true;
    let backX = -1;
    let backY = -1;
    if (restore) {
      const before = NativeInput.getPointerLocation();
      if (before.ok) {
        backX = Math.round(before.x);
        backY = Math.round(before.y);
      }
    }
    let result: Object;
    if (op === 'move') {
      result = NativeInput.injectMouseMove(x, y);
    } else if (op === 'button') {
      const button: number = args['button'] === undefined ? 0 : this.numberArg(args, 'button');
      const down: boolean = args['down'] !== false;
      result = NativeInput.injectMouseButton(x, y, button, down);
    } else if (op === 'axis') {
      const axisType: number = args['axisType'] === undefined ? 0 : this.numberArg(args, 'axisType');
      const axisValue: number = args['axisValue'] === undefined ? 1 : this.numberArg(args, 'axisValue');
      result = NativeInput.injectMouseAxis(x, y, axisType, axisValue);
    } else {
      throw new Error('ndkInjectMouse: op must be move|button|axis');
    }
    let restored = false;
    if (restore && backX >= 0 && backY >= 0) {
      NativeInput.injectMouseMove(backX, backY);
      restored = true;
    }
    const body: string = JSON.stringify(result);
    return '{"result":' + body + ',"restored":' + (restored ? 'true' : 'false') +
      ',"restoredTo":[' + backX.toString() + ',' + backY.toString() + ']}';
  }

  /**
   * NDK 全局鼠标事件监听（INPUT_MONITORING，试用 ACL 期内可用；事件经 postEvent 落盘）。
   * args: {op:'start'|'stop'} → 事件流 'mouse_event' {action,x,y,button,windowId}
   */
  private ndkMouseWatch(args: Record<string, Object>): Promise<string> {
    const op: string = this.stringArg(args, 'op');
    if (op === 'start') {
      const r = NativeInput.startMouseMonitor((e) => {
        this.postEvent('mouse_event', JSON.stringify({
          action: e.action, x: e.x, y: e.y, button: e.button, windowId: e.windowId
        }));
      });
      return this.ndkResult(r);
    }
    if (op === 'stop') {
      return this.ndkResult(NativeInput.stopMouseMonitor());
    }
    throw new Error('ndkMouseWatch: op must be start|stop');
  }

  /**
   * 触摸/触控板多指监视（INPUT_MONITORING）。
   *
   * 为什么不复用 ndkMouseWatch：OH_Input_AddMouseEventMonitor 文档明确
   * 「仅当屏幕录制场景在用时可调用，否则调用不生效」（实测 ret=201），
   * 而 OH_Input_AddTouchEventMonitor 无此前置条件——触控板多指事件在 PC 上
   * 按触摸设备上报（SOURCE_TYPE_TOUCHPAD=3），要观察多指手势必须走这条。
   *
   * args: { op: 'start'|'stop' }。事件以 `touch_event` 打到宿主 /ui-events
   * （GET http://127.0.0.1:3131/ui-events 可读）。
   */
  private ndkTouchWatch(args: Record<string, Object>): Promise<string> {
    const op: string = this.stringArg(args, 'op');
    if (op === 'start') {
      const r = NativeInput.startTouchMonitor((e) => {
        this.postEvent('touch_event', JSON.stringify({
          action: e.action, fingerId: e.fingerId, toolType: e.toolType,
          displayId: e.displayId, windowId: e.windowId, pressure: e.pressure,
          displayX: e.displayX, displayY: e.displayY,
          globalX: e.globalX, globalY: e.globalY
        }));
      });
      return this.ndkResult(r);
    }
    if (op === 'stop') {
      return this.ndkResult(NativeInput.stopTouchMonitor());
    }
    throw new Error('ndkTouchWatch: op must be start|stop');
  }

  /**
   * 轴事件监视（INPUT_MONITORING）——**触控板双指的真正通路**。
   *
   * 2026-10-12 纠正：touch 事件属于触摸屏/笔（本机有触摸屏），触控板的双指数据走
   * axis 事件——`OH_Input_GetAxisEventSourceType` 是唯一能读来源的 getter
   * （1=MOUSE 2=TOUCHSCREEN 3=TOUCHPAD）。轴事件只有 PINCH(1)/SCROLL(2) 两类、
   * BEGIN/UPDATE/END 三态；三指/四指滑动不在轴模型里（系统 shell 消费）。
   *
   * args: { op: 'start'|'stop' } → 事件以 `axis_event` 打到宿主 /ui-events。
   */
  private ndkAxisWatch(args: Record<string, Object>): Promise<string> {
    const op: string = this.stringArg(args, 'op');
    if (op === 'start') {
      const r = NativeInput.startAxisMonitor((e) => {
        this.postEvent('axis_event', JSON.stringify({
          action: e.action, eventType: e.eventType, sourceType: e.sourceType,
          pinchValue: e.pinchValue, scrollValue: e.scrollValue,
          displayId: e.displayId, windowId: e.windowId,
          globalX: e.globalX, globalY: e.globalY,
          displayX: e.displayX, displayY: e.displayY
        }));
      });
      return this.ndkResult(r);
    }
    if (op === 'stop') {
      return this.ndkResult(NativeInput.stopAxisMonitor());
    }
    throw new Error('ndkAxisWatch: op must be start|stop');
  }

  /**
   * 探针（2026-10-12）：验证「屏幕录制场景在用」是否是 INPUT_MONITORING 监视器的前置条件。
   *
   * 背景：mouse/touch/axis 三个监视器在 INPUT_MONITORING 已授（aclProbe=granted）的前提下
   * 一律返回 **201**；而 `OH_Input_AddMouseEventMonitor` 的文档明确写着
   * 「This API can be called only when the screen recording scenario is in use.
   *   Otherwise, the call does not take effect.」
   * → 本探针把「开录屏 + 挂 axis 监视器」放进同一次调用（桥是串行执行，分两次调必然错过窗口）。
   */
  private async ndkMonitorWhileRecording(args: Record<string, Object>): Promise<string> {
    const path: string = this.abilityContext.filesDir + '/monitor-while-recording.mp4';
    const holdMs: number = args['seconds'] === undefined ? 25000 : this.numberArg(args, 'seconds') * 1000;
    let recorder: media.AVScreenCaptureRecorder | null = null;
    let opened: fileIo.File | null = null;
    let code: number = -999;
    let total: number = 0;
    let byPad: number = 0;
    let byMouse: number = 0;
    let byScreen: number = 0;
    const samples: string[] = [];
    try {
      recorder = await media.createAVScreenCaptureRecorder();
      if (recorder === null) {
        return '{"ok":false,"stage":"create"}';
      }
      opened = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      const config: media.AVScreenCaptureRecordConfig = { fd: opened.fd };
      await recorder.init(config);
      await recorder.startRecording();
      await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 1000); });
      code = NativeInput.startAxisMonitor((e) => {
        total = total + 1;
        if (e.sourceType === 3) {
          byPad = byPad + 1;
        } else if (e.sourceType === 2) {
          byScreen = byScreen + 1;
        } else {
          byMouse = byMouse + 1;
        }
        if (samples.length < 6) {
          samples.push('t=' + e.eventType.toString() + ',s=' + e.sourceType.toString() +
            ',a=' + e.action.toString() + ',p=' + e.pinchValue.toFixed(2) +
            ',sc=' + e.scrollValue.toFixed(2));
        }
        this.postEvent('axis_event', JSON.stringify({
          action: e.action, eventType: e.eventType, sourceType: e.sourceType,
          pinchValue: e.pinchValue, scrollValue: e.scrollValue,
          globalX: e.globalX, globalY: e.globalY
        }));
      }).code;
      await new Promise<void>((resolve: () => void) => { setTimeout(resolve, holdMs); });
      return '{"ok":true,"monitorCode":' + code.toString() + ',"total":' + total.toString() +
        ',"byTouchpad":' + byPad.toString() + ',"byMouse":' + byMouse.toString() +
        ',"byTouchscreen":' + byScreen.toString() + ',"samples":' + JSON.stringify(samples) + '}';
    } catch (e) {
      const m = e instanceof Error ? e.message : String(e);
      return '{"ok":false,"error":"' + this.esc(m.slice(0, 150)) + '","monitorCode":' + code.toString() +
        ',"total":' + total.toString() + '}';
    } finally {
      try { NativeInput.stopAxisMonitor(); } catch { /* ignore */ }
      if (opened !== null) {
        try { fileIo.closeSync(opened); } catch { /* ignore */ }
      }
      if (recorder !== null) {
        try { await recorder.stopRecording(); } catch { /* ignore */ }
        try { await recorder.release(); } catch { /* ignore */ }
      }
    }
  }

  /**
   * NDK 进程内单帧截屏（OH_AVScreenCapture，RGBA8888）。
   * 替代「ArkTS截图→沙箱文件→fetchFile base64」三跳链：直接在 native 层拿 buffer。
   * args: {width?, height?}（缺省 3840×2160）→ RGBA 原始数据写 filesDir，宿主用 fetchFile 取回。
   */
  private async ndkScreenshot(args: Record<string, Object>): Promise<string> {
    const width: number = args['width'] === undefined ? 3840 : this.numberArg(args, 'width');
    const height: number = args['height'] === undefined ? 2160 : this.numberArg(args, 'height');
    const shot = await NativeInput.captureScreenshot(width, height);
    return this.saveRgbaShot(shot, 'ndk-capture');
  }

  /** 把 NDK 截图结果（RGBA buffer）落盘到 filesDir，返回给宿主的元数据 JSON */
  private saveRgbaShot(shot: NativeScreenshot, prefix: string): string {
    if (shot.code !== 0 || shot.data === undefined) {
      return JSON.stringify({
        ok: false, code: shot.code, width: shot.width, height: shot.height
      });
    }
    const path: string = this.abilityContext.filesDir + '/' + prefix + '-' + Date.now().toString() + '.rgba';
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
    fileIo.writeSync(file.fd, shot.data);
    fileIo.closeSync(file);
    return JSON.stringify({
      ok: true, code: shot.code, width: shot.width, height: shot.height,
      stride: shot.stride, size: shot.size, path: path
    });
  }

  /**
   * v3：所有主窗信息（OH_WindowManager_GetAllMainWindowInfo @21，需 CUSTOM_SCREEN_CAPTURE）。
   * → {code, count, windows:[{displayId, windowId, showing, label}]}
   */
  private ndkMainWindows(): Promise<string> {
    return Promise.resolve(JSON.stringify(NativeInput.getAllMainWindows()));
  }

  /**
   * v3：轻量整屏截图（OH_NativeDisplayManager_CaptureScreenPixelmap @14）。
   * args: {displayId?}（缺省 0=默认屏）→ RGBA 落盘，宿主 fetchFile 取回
   */
  private async ndkDisplayCapture(args: Record<string, Object>): Promise<string> {
    const displayId: number = args['displayId'] === undefined ? 0 : this.numberArg(args, 'displayId');
    const shot = await NativeInput.captureDisplay(displayId);
    return this.saveRgbaShot(shot, 'ndk-display');
  }

  /**
   * v3：按窗截图（OH_WindowManager_GetMainWindowSnapshot @21，需 CUSTOM_SCREEN_CAPTURE）。
   * args: {windowId, width, height}（width/height 用窗口 rect 尺寸；windowId 从 ndkMainWindows 取）
   */
  private async ndkWindowSnapshot(args: Record<string, Object>): Promise<string> {
    const windowId: number = this.numberArg(args, 'windowId');
    const width: number = args['width'] === undefined ? 0 : this.numberArg(args, 'width');
    const height: number = args['height'] === undefined ? 0 : this.numberArg(args, 'height');
    if (windowId === 0) {
      throw new Error('ndkWindowSnapshot: "windowId" is required (see ndkMainWindows)');
    }
    const shot = await NativeInput.captureWindow(windowId, width, height);
    return this.saveRgbaShot(shot, 'ndk-window');
  }

  /**
   * knowledge/14 #14: read a system setting (read is permission-free).
   * args: {name} — raw key, or constant path like display.SCREEN_BRIGHTNESS_STATUS.
   */
  private async settingsRead(args: Record<string, Object>): Promise<string> {
    const name: string = this.stringArg(args, 'name');
    if (name.length === 0) {
      throw new Error('settingsRead: "name" is required');
    }
    let key: string = name;
    if (name === 'display.SCREEN_BRIGHTNESS_STATUS') {
      key = settings.display.SCREEN_BRIGHTNESS_STATUS;
    } else if (name === 'display.FONT_SCALE') {
      key = settings.display.FONT_SCALE;
    } else if (name === 'display.AUTO_SCREEN_BRIGHTNESS') {
      key = settings.display.AUTO_SCREEN_BRIGHTNESS;
    }
    try {
      const v: string = await settings.getValue(this.abilityContext, key);
      return '{"name":"' + this.esc(name) + '","key":"' + this.esc(key) + '","value":"' + this.esc(v) + '"}';
    } catch (e) {
      const m = e instanceof Error ? e.message : String(e);
      return '{"name":"' + this.esc(name) + '","error":"' + this.esc(m.slice(0, 120)) + '"}';
    }
  }

  /**
   * AVScreenCaptureRecorder probe (2026-10-12, CC msg-69): the media module has
   * a programmatic screen-recording API with NO @permission on any method —
   * if third-party runtime allows it, this replaces the Meta+Shift+R shortcut.
   * Records 3s into filesDir and reports the byte count.
   */
  private async screenRecordProbe(): Promise<string> {
    const path: string = this.abilityContext.filesDir + '/acl-probe-recording.mp4';
    let recorder: media.AVScreenCaptureRecorder | null = null;
    let opened: fileIo.File | null = null;
    try {
      recorder = await media.createAVScreenCaptureRecorder();
      if (recorder === null) {
        return '{"ok":false,"stage":"create","error":"createAVScreenCaptureRecorder returned null"}';
      }
      opened = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      const config: media.AVScreenCaptureRecordConfig = { fd: opened.fd };
      await recorder.init(config);
      await recorder.startRecording();
      await new Promise<void>((resolve) => { setTimeout(resolve, 3000); });
      await recorder.stopRecording();
      fileIo.closeSync(opened);
      opened = null;
      const st: fileIo.Stat = fileIo.statSync(path);
      return '{"ok":true,"bytes":' + st.size.toString() +
        ',"note":"programmatic recording works — shortcut path replaceable"}';
    } catch (e) {
      const m = e instanceof Error ? e.message : String(e);
      return '{"ok":false,"error":"' + this.esc(m.slice(0, 200)) + '"}';
    } finally {
      if (opened !== null) {
        try { fileIo.closeSync(opened); } catch { /* ignore */ }
      }
      if (recorder !== null) {
        try { await recorder.release(); } catch { /* ignore */ }
      }
    }
  }

  /**
   * Trial-profile ACL probe (2026-10-11): runtime-verifies the 7 trial ACLs.
   * verifyAccessToken gives the grant state without side effects; inputMonitor
   * on/off and getAbilityInfo are functional probes for the API paths.
   */
  private async aclProbe(args: Record<string, Object>): Promise<string> {
    const perms: Array<string> = [
      'ohos.permission.CUSTOM_SCREEN_RECORDING',
      'ohos.permission.CONTROL_DEVICE',
      'ohos.permission.INTERCEPT_INPUT_EVENT',
      'ohos.permission.INPUT_MONITORING',
      'ohos.permission.MANAGE_RECENT_SNAPSHOT',
      'ohos.permission.READ_PASTEBOARD',
      'ohos.permission.GET_ABILITY_INFO'
    ];
    const atManager = abilityAccessCtrl.createAtManager();
    const selfInfo = await bundleManager.getBundleInfoForSelf(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
    const tokenId: number = selfInfo.appInfo.accessTokenId;
    let out: string = '{"grants":{';
    let first: boolean = true;
    for (const p of perms) {
      let st: string = '"unknown"';
      try {
        const g: abilityAccessCtrl.GrantStatus = await atManager.verifyAccessToken(tokenId, p);
        // 注意：token=granted 只代表持有权限，不代表系统有对应 API 可用
        // （反例：INPUT_MONITORING granted 但本 SDK 无 inputMonitor 模块）
        st = g === 0 ? '"granted"' : '"denied"';
      } catch (e) {
        const m = e instanceof Error ? e.message : String(e);
        st = m.includes('not') && m.includes('request') ? '"not-declared"' : '"error:' + this.esc(m.slice(0, 60)) + '"';
      }
      out += (first ? '' : ',') + '"' + p.slice(16) + '":' + st;
      first = false;
    }
    out += '}';
    // functional probe (OPT-IN, has side effect: really injects an 'a' key):
    // only runs when called as aclProbe {"inject":true}. Default = grants only.
    const doInject: boolean = args['inject'] === true;
    if (doInject) {
      try {
        const kc = await inputEventClient.createKeyboardController();
        await kc.pressKey(2017);
        await kc.releaseKey(2017);
        out += ',"injectKey":"ok"';
      } catch (e) {
        const m = e instanceof Error ? e.message : String(e);
        out += m.includes('201') || m.includes('Permission') ?
          ',"injectKey":"denied"' :
          ',"injectKey":"error:' + this.esc(m.slice(0, 100)) + '"';
      }
    }
    // note: this SDK only exposes getAbilityInfo(uri, flags) — the
    // (bundleName, abilityName) overload that exercises GET_ABILITY_INFO does
    // not exist here, so grant state above is the probe for that permission.
    out += '}';
    return out;
  }

  /**
   * Probe whether the in-process UiTest API (@ohos.UiTest) is usable.
   * If it works, DSH can drive the whole machine without hdc.
   */
  /**
   * Probes `fileIo.createWatcher` on an arbitrary path.
   *
   * Question it answers: the API doc says it observes an "application sandbox
   * path". This app's own sandbox root differs from the user HOME view that DSH
   * and the bridge write to, so before building any file-event driven feature
   * we must know whether a non-sandbox path is watchable at all, and whether
   * events actually fire (the docs' wording alone does not settle it).
   *
   * args: { path: string, events?: number, holdMs?: number }
   * Returns the observed event count plus the first few events.
   */
  private async watchProbe(args: Record<string, Object>): Promise<string> {
    const path = this.stringArg(args, 'path');
    if (path.length === 0) {
      throw new Error('watchProbe: "path" is required');
    }
    const events = this.numberArg(args, 'events');
    const holdMs = this.numberArg(args, 'holdMs');
    const mask = events > 0 ? events : WATCH_MASK_ALL;
    const wait = holdMs > 0 ? holdMs : 4000;
    const seen: string[] = [];
    let watcher: fileIo.Watcher | undefined;
    try {
      // NOTE: `WatchEvent` is NOT exported from the fileIo namespace (only
      // `Watcher` is), so the callback parameter type is left inferred —
      // naming it explicitly fails to compile on this SDK.
      watcher = fileIo.createWatcher(path, mask, (event) => {
        if (seen.length < 20) {
          seen.push(event.fileName + '#' + event.event.toString());
        }
      });
      watcher.start();
      await new Promise<void>((resolve) => { setTimeout(() => { resolve(); }, wait); });
    } catch (err) {
      return JSON.stringify({
        ok: false, path, error: this.text(err), events: seen.length, sample: seen
      });
    } finally {
      try { watcher?.stop(); } catch { /* already gone */ }
    }
    return JSON.stringify({
      ok: true, path, mask, waitedMs: wait, events: seen.length, sample: seen
    });
  }

  private async uiTestProbe(): Promise<string> {
    const dumpPath = '/data/storage/el2/base/dsh-home/tmp/uitest-probe.json';
    try {
      const driver: Driver = Driver.create();
      let dumped = false;
      let dumpError = '';
      try {
        dumped = await driver.dumpLayout(dumpPath);
      } catch (de) {
        dumpError = this.text(de);
      }
      let found = -1;
      let findError = '';
      try {
        const comps: Array<Component> = await driver.findComponents(ON.clickable(true));
        found = comps.length;
      } catch (fe) {
        findError = this.text(fe);
      }
      return '{"ok":true,"dump":' + (dumped ? 'true' : 'false') +
        ',"dumpError":"' + dumpError.replace(/"/g, '\\"') + '"' +
        ',"clickableFound":' + found.toString() +
        ',"findError":"' + findError.replace(/"/g, '\\"') + '"}';
    } catch (e) {
      return '{"ok":false,"error":"' + this.text(e).replace(/"/g, '\\"') + '"}';
    }
  }
  // ---------------------------------------------------------------------
  // Window perception & self-window control
  //
  // Reachability notes (verified against the signing profile: apl=normal,
  // acls=[] so NO system_basic permission is available):
  //   * getAllWindowLayoutInfo / getWindowsByCoordinate / getGlobalWindowMode
  //     need no permission at all.
  //   * getAllMainWindowInfo / getMainWindowSnapshot need
  //     ohos.permission.CUSTOM_SCREEN_CAPTURE which is availableLevel "normal"
  //     (user_grant) -> declare it in module.json5 and the first call prompts.
  //   * Window.moveWindowTo/resize/maximize/recover only ever affect THIS
  //     app's own windows. There is no public API to move another app's
  //     window, by design.
  // ---------------------------------------------------------------------

  /** Escapes a string for embedding in a hand-built JSON literal. */
  private esc(value: string): string {
    return value.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n').replace(/\r/g, '\\r');
  }

  /** Picks the display to query: explicit arg, else the default display. */
  private resolveDisplayId(args: Record<string, Object>): number {
    const explicit = this.numberArg(args, 'displayId');
    if (explicit > 0) {
      return explicit;
    }
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      return d.id;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getDefaultDisplaySync failed: %{public}s', this.text(err));
      return 0;
    }
  }

  /**
   * All windows currently visible on a display, ordered top-most first.
   *
   * Needs no permission. Each entry is the window rectangle in px; the doc
   * warns the width/height are already scale-adjusted, and that a window
   * covered by a translucent or animating window still counts as visible, so
   * callers should reason about occlusion themselves using the z-order.
   */
  private async getWindowLayouts(args: Record<string, Object>): Promise<string> {
    const displayId = this.resolveDisplayId(args);
    try {
      const infos: Array<window.WindowLayoutInfo> = await window.getAllWindowLayoutInfo(displayId);
      const parts: string[] = [];
      for (let i = 0; i < infos.length; i++) {
        const r = infos[i].windowRect;
        parts.push('{"index":' + i.toString() +
          ',"left":' + r.left.toString() +
          ',"top":' + r.top.toString() +
          ',"width":' + r.width.toString() +
          ',"height":' + r.height.toString() + '}');
      }
      return '{"ok":true,"displayId":' + displayId.toString() +
        ',"count":' + infos.length.toString() +
        ',"windows":[' + parts.join(',') + ']}';
    } catch (err) {
      throw new Error('getWindowLayouts: ' + this.text(err));
    }
  }

  /**
   * Every main window on the system: windowId, display, showing, label.
   *
   * This is the key to per-window capture, because snapshotWindow() takes the
   * windowIds returned here. Requires ohos.permission.CUSTOM_SCREEN_CAPTURE.
   */
  private async listMainWindows(): Promise<string> {
    try {
      const infos: Array<window.MainWindowInfo> = await window.getAllMainWindowInfo();
      const parts: string[] = [];
      for (let i = 0; i < infos.length; i++) {
        const w = infos[i];
        parts.push('{"displayId":' + w.displayId.toString() +
          ',"windowId":' + w.windowId.toString() +
          ',"showing":' + (w.showing ? 'true' : 'false') +
          ',"label":"' + this.esc(w.label) + '"}');
      }
      return '{"ok":true,"count":' + infos.length.toString() +
        ',"windows":[' + parts.join(',') + ']}';
    } catch (err) {
      throw new Error('listMainWindows: ' + this.text(err) +
        ' (needs ohos.permission.CUSTOM_SCREEN_CAPTURE)');
    }
  }

  /**
   * Captures the given main windows to PNG files under the DSH home.
   *
   * Requires ohos.permission.CUSTOM_SCREEN_CAPTURE. `args.windowIds` is a
   * comma-separated list; `args.useCache` (default true) reuses the system's
   * existing snapshot instead of forcing a fresh capture.
   */
  private async snapshotWindow(args: Record<string, Object>): Promise<string> {
    const raw = this.stringArg(args, 'windowIds');
    if (raw.length === 0) {
      throw new Error('snapshotWindow: "windowIds" is required (comma-separated, from listMainWindows)');
    }
    const ids: Array<number> = [];
    for (const piece of raw.split(',')) {
      const trimmed = piece.trim();
      if (trimmed.length === 0) {
        continue;
      }
      const parsed = Number.parseInt(trimmed, 10);
      if (Number.isNaN(parsed)) {
        throw new Error('snapshotWindow: invalid window id "' + trimmed + '"');
      }
      ids.push(parsed);
    }
    if (ids.length === 0) {
      throw new Error('snapshotWindow: no valid window ids parsed from "' + raw + '"');
    }
    const config: window.WindowSnapshotConfiguration = {
      useCache: this.stringArg(args, 'useCache') !== 'false'
    };
    try {
      const maps: Array<image.PixelMap | undefined> = await window.getMainWindowSnapshot(ids, config);
      // NOTE: the ArkTS process sees its OWN sandbox, not the dsh home on the
      // host FS — a literal /data/storage/el2/base/dsh-home/tmp path does not
      // resolve here. Use the ability's filesDir, which is the app-sandbox
      // equivalent of <dsh home>/tmp (both land in the same bundle sandbox).
      const dir = this.abilityContext.filesDir + '/dsh-shots';
      try {
        fileIo.mkdirSync(dir, true);
      } catch (de) {
        hilog.warn(DOMAIN, TAG, 'snapshotWindow: mkdir %{public}s failed: %{public}s', dir, this.text(de));
      }
      const parts: string[] = [];
      for (let i = 0; i < maps.length; i++) {
        const map: image.PixelMap | undefined = maps[i];
        if (map === undefined || map === null) {
          parts.push('{"windowId":' + ids[i].toString() + ',"ok":false}');
          continue;
        }
        const stamp = Date.now().toString();
        const abs = dir + '/win-' + ids[i].toString() + '-' + stamp + '.png';
        try {
          const packer: image.ImagePacker = image.createImagePacker();
          const opt: image.PackingOption = { format: 'image/png', quality: 100 };
          const buf: ArrayBuffer = await packer.packing(map, opt);
          const file: fileIo.File = fileIo.openSync(abs,
            fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
          fileIo.writeSync(file.fd, buf);
          fileIo.closeSync(file);
          parts.push('{"windowId":' + ids[i].toString() + ',"ok":true,"file":"' + this.esc(abs) + '"}');
        } catch (pe) {
          parts.push('{"windowId":' + ids[i].toString() + ',"ok":false,"error":"' + this.esc(this.text(pe)) + '"}');
        }
      }
      return '{"ok":true,"count":' + maps.length.toString() + ',"files":[' + parts.join(',') + ']}';
    } catch (err) {
      throw new Error('snapshotWindow: ' + this.text(err) +
        ' (needs ohos.permission.CUSTOM_SCREEN_CAPTURE)');
    }
  }

  /**
   * Core Vision Kit OCR (`@kit.CoreVisionKit` -> textRecognition) over an image
   * supplied either as base64 (`base64`) or as an absolute path (`path`) that
   * this ArkTS process can read (its own sandbox / screenshot dir).
   *
   * Returns the full text plus per-line boxes, so a caller can both read text
   * off a screen and locate it (the boxes are in the decoded image's pixels).
   * No permission is required for the file-based path.
   */
  private async ocrImage(args: Record<string, Object>): Promise<string> {
    const b64 = this.stringArg(args, 'base64');
    const path = this.stringArg(args, 'path');
    if (b64.length === 0 && path.length === 0) {
      throw new Error('ocrImage: "base64" or "path" is required');
    }
    let buf: ArrayBuffer | undefined = undefined;
    let filePath = path;
    if (b64.length > 0) {
      const helper = new util.Base64Helper();
      const bytes: Uint8Array = helper.decodeSync(b64);
      buf = bytes.buffer as ArrayBuffer;
      filePath = '';
    }
    const started = Date.now();
    let fd = -1;
    let map: image.PixelMap | undefined = undefined;
    let inited = false;
    try {
      let source: image.ImageSource;
      if (buf !== undefined) {
        source = image.createImageSource(buf);
      } else {
        fd = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY).fd;
        source = image.createImageSource(fd);
      }
      // Core Vision Kit only accepts RGBA_8888 pixel maps.
      const decodeOpts: image.DecodingOptions = {
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      };
      map = await source.createPixelMap(decodeOpts);
      const info: image.ImageInfo = await map.getImageInfo();
      try {
        inited = await textRecognition.init();
      } catch (ie) {
        hilog.warn(DOMAIN, TAG, 'ocrImage: init failed: %{public}s', this.text(ie));
      }
      const visionInfo: textRecognition.VisionInfo = { pixelMap: map };
      const result: textRecognition.TextRecognitionResult = await textRecognition.recognizeText(visionInfo);
      const lines: string[] = [];
      for (const block of result.blocks) {
        for (const line of block.lines) {
          const pts: string[] = [];
          for (const point of line.cornerPoints) {
            pts.push('[' + point.x.toString() + ',' + point.y.toString() + ']');
          }
          lines.push('{"text":"' + this.esc(line.value) + '","box":[' + pts.join(',') + ']}');
        }
      }
      return '{"ok":true' +
        ',"width":' + info.size.width.toString() +
        ',"height":' + info.size.height.toString() +
        ',"elapsedMs":' + (Date.now() - started).toString() +
        ',"value":"' + this.esc(result.value) + '"' +
        ',"lines":[' + lines.join(',') + ']}';
    } catch (err) {
      throw new Error('ocrImage: ' + this.text(err));
    } finally {
      if (inited) {
        try {
          await textRecognition.release();
        } catch (re) {
          hilog.warn(DOMAIN, TAG, 'ocrImage: release failed: %{public}s', this.text(re));
        }
      }
      if (map !== undefined) {
        try {
          await map.release();
        } catch (me) {
          hilog.warn(DOMAIN, TAG, 'ocrImage: pixelMap release failed: %{public}s', this.text(me));
        }
      }
      if (fd >= 0) {
        try {
          fileIo.closeSync(fd);
        } catch (ce) {
          hilog.warn(DOMAIN, TAG, 'ocrImage: close fd failed: %{public}s', this.text(ce));
        }
      }
    }
  }

  /** Window mode of the foreground window on a display. */
  private async getGlobalWindowMode(args: Record<string, Object>): Promise<string> {
    const displayId = this.resolveDisplayId(args);
    try {
      const mode: number = await window.getGlobalWindowMode(displayId);
      return '{"ok":true,"displayId":' + displayId.toString() + ',"mode":' + mode.toString() + '}';
    } catch (err) {
      throw new Error('getGlobalWindowMode: ' + this.text(err));
    }
  }

  /** Rectangle, status and mode of this app's own main window. */
  private async getSelfWindowInfo(): Promise<string> {
    try {
      const win: window.Window = await window.getLastWindow(this.abilityContext);
      const props: window.WindowProperties = win.getWindowProperties();
      const globalRect = win.getGlobalRect();
      const status: window.WindowStatusType = win.getWindowStatus();
      // NOTE: this SDK's WindowProperties carries no bundleName (only id,
      // displayId?, name?, windowRect, drawableRect, ...), so the bundle name
      // is taken from the ability context instead.
      const displayId = (props.displayId !== undefined) ? props.displayId : 0;
      const winName = (props.name !== undefined) ? props.name : '';
      return '{"ok":true' +
        ',"windowId":' + props.id.toString() +
        ',"displayId":' + displayId.toString() +
        ',"windowName":"' + this.esc(winName) + '"' +
        ',"bundleName":"' + this.esc(this.abilityContext.abilityInfo.bundleName) + '"' +
        ',"rect":{"left":' + props.windowRect.left.toString() +
        ',"top":' + props.windowRect.top.toString() +
        ',"width":' + props.windowRect.width.toString() +
        ',"height":' + props.windowRect.height.toString() + '}' +
        ',"globalRect":{"left":' + globalRect.left.toString() +
        ',"top":' + globalRect.top.toString() +
        ',"width":' + globalRect.width.toString() +
        ',"height":' + globalRect.height.toString() + '}' +
        ',"status":' + status.toString() + '}';
    } catch (err) {
      throw new Error('getSelfWindowInfo: ' + this.text(err));
    }
  }

  /** Moves this app's own window. `global` picks display-absolute coords. */
  private async moveSelfWindow(args: Record<string, Object>): Promise<string> {
    const x = this.numberArg(args, 'x');
    const y = this.numberArg(args, 'y');
    const useGlobal = this.stringArg(args, 'global') === 'true';
    try {
      const win: window.Window = await window.getLastWindow(this.abilityContext);
      if (useGlobal) {
        await win.moveWindowToGlobal(x, y);
      } else {
        await win.moveWindowTo(x, y);
      }
      return '{"ok":true,"x":' + x.toString() + ',"y":' + y.toString() +
        ',"global":' + (useGlobal ? 'true' : 'false') + '}';
    } catch (err) {
      throw new Error('moveSelfWindow: ' + this.text(err));
    }
  }

  /** Resizes this app's own window, in px. */
  private async resizeSelfWindow(args: Record<string, Object>): Promise<string> {
    const width = this.numberArg(args, 'width');
    const height = this.numberArg(args, 'height');
    if (width <= 0 || height <= 0) {
      throw new Error('resizeSelfWindow: "width" and "height" must be positive');
    }
    try {
      const win: window.Window = await window.getLastWindow(this.abilityContext);
      await win.resize(width, height);
      return '{"ok":true,"width":' + width.toString() + ',"height":' + height.toString() + '}';
    } catch (err) {
      throw new Error('resizeSelfWindow: ' + this.text(err));
    }
  }

  /**
   * Switches this app's own window between full screen / floating / recover /
   * minimize / maximize.
   */
  private async setSelfWindowMode(args: Record<string, Object>): Promise<string> {
    const mode = this.stringArg(args, 'mode');
    if (mode.length === 0) {
      throw new Error('setSelfWindowMode: "mode" is required ' +
        '(fullscreen|exitfullscreen|maximize|minimize|recover|topmost|untopmost)');
    }
    try {
      const win: window.Window = await window.getLastWindow(this.abilityContext);
      if (mode === 'fullscreen') {
        await win.setFullScreen(true);
      } else if (mode === 'exitfullscreen') {
        await win.setFullScreen(false);
      } else if (mode === 'maximize') {
        await win.maximize();
      } else if (mode === 'minimize') {
        await win.minimize();
      } else if (mode === 'recover') {
        await win.recover();
      } else if (mode === 'topmost') {
        // NOTE: this SDK has no window.WindowMode / setWindowMode (only the
        // GlobalWindowMode union returned by getGlobalWindowMode), so the
        // "float" case is served by setWindowTopmost instead.
        await win.setWindowTopmost(true);
      } else if (mode === 'untopmost') {
        await win.setWindowTopmost(false);
      } else {
        throw new Error('setSelfWindowMode: unknown mode "' + mode + '"');
      }
      return '{"ok":true,"mode":"' + this.esc(mode) + '"}';
    } catch (err) {
      throw new Error('setSelfWindowMode: ' + this.text(err));
    }
  }

  /**
   * Reads a file out of THIS APP's private sandbox and returns it base64-encoded.
   *
   * Why it exists: snapshotWindow() writes PNGs into the HAP's own sandbox
   * (abilityContext.filesDir = /data/storage/el2/base/haps/entry/files), which
   * no uid-2000 shell / hdc session can read ("Permission denied"). Without a
   * way to pull bytes out, a per-window screenshot would be unreachable by the
   * node side. Small by design: pass `path` (absolute, inside the sandbox) and
   * an optional `maxBytes` guard (default 4 MiB) so a big file cannot blow up
   * the loopback JSON reply.
   */
  private async fetchFile(args: Record<string, Object>): Promise<string> {
    const p = this.stringArg(args, 'path');
    if (p.length === 0) {
      throw new Error('fetchFile: "path" is required (absolute path inside this app sandbox)');
    }
    let maxBytes = 4 * 1024 * 1024;
    const rawMax = this.numberArg(args, 'maxBytes');
    if (rawMax > 0) {
      maxBytes = rawMax;
    }
    try {
      const st: fileIo.Stat = fileIo.statSync(p);
      const size = st.size;
      // 分片拉取：agent→bridge 的 POST 超过 ~1MB 会静默失败（实测 700KB 过 1.2MB 挂），
      // 大文件用 offset/length 分片（建议 ≤512KB/片），宿主侧拼接。
      const rawOffset = this.numberArg(args, 'offset');
      const start = rawOffset > 0 && rawOffset < size ? rawOffset : 0;
      let want = size - start;
      const rawLen = this.numberArg(args, 'length');
      if (rawLen > 0 && rawLen < want) {
        want = rawLen;
      }
      if (want > maxBytes) {
        throw new Error('fetchFile: slice is ' + want.toString() + ' bytes, over the ' +
          maxBytes.toString() + ' byte cap; use offset/length chunks');
      }
      const file: fileIo.File = fileIo.openSync(p, fileIo.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(want);
      const read = fileIo.readSync(file.fd, buf, { offset: start, length: want });
      fileIo.closeSync(file);
      const bytes = new Uint8Array(buf.slice(0, read));
      const b64 = this.base64(bytes);
      return '{"ok":true,"path":"' + this.esc(p) + '","size":' + size.toString() +
        ',"offset":' + start.toString() + ',"read":' + read.toString() +
        ',"base64":"' + b64 + '"}';
    } catch (err) {
      throw new Error('fetchFile: ' + this.text(err));
    }
  }

  // ---------------------------------------------------------------------------
  // Desktop Extension Kit (PC status bar / 状态栏)
  // ---------------------------------------------------------------------------

  private statusBarAdded = false;
  private statusBarLeftClicks = 0;
  private statusBarMenuClicks: string[] = [];
  private clipboardWatchCb: (() => void) | undefined = undefined;
  private hotkeyWatchCb: Callback<inputConsumer.HotkeyOptions> | undefined = undefined;
  private hotkeyWatchOpts: inputConsumer.HotkeyOptions | undefined = undefined;
  private fsWatcher: Watcher | undefined = undefined;
  private statusBarIconCb: Callback<emitter.EventData> | undefined = undefined;
  private statusBarMenuCb: Callback<emitter.EventData> | undefined = undefined;

  /**
   * Adds the DSH icon to the PC status bar (Desktop Extension Kit, no permission).
   *
   * args:
   *   title?     hover/left-click popup title (default "DSH")
   *   hoverTips? tooltip on hover (1~128 chars)
   *   menu?      right-click menu, "标题:code;标题2:code2" (<=20 items total)
   *
   * `quickOperation.abilityName` is intentionally empty: left clicks are then
   * delivered through the `statusBarIconClick` event instead of opening a
   * StatusBarViewExtensionAbility popup (which would need a UIExtensionAbility).
   * Only one status-bar icon per app is allowed; a repeated add is a no-op.
   */
  private async statusBarAdd(args: Record<string, Object>): Promise<string> {
    const titleRaw = this.stringArg(args, 'title');
    const title = titleRaw.length > 0 ? titleRaw : 'DSH';
    const hover = this.stringArg(args, 'hoverTips');
    const menuSpec = this.stringArg(args, 'menu');
    try {
      const rm = this.abilityContext.resourceManager;
      const whiteData = rm.getRawFileContentSync('dsh_statusbar_white.png');
      const whiteSrc = image.createImageSource(whiteData.buffer as ArrayBuffer);
      const whiteMap = await whiteSrc.createPixelMap();
      const blackData = rm.getRawFileContentSync('dsh_statusbar_black.png');
      const blackSrc = image.createImageSource(blackData.buffer as ArrayBuffer);
      const blackMap = await blackSrc.createPixelMap();
      const icons: statusBarManager.StatusBarIcon = { white: whiteMap, black: blackMap };
      const quick: statusBarManager.QuickOperation = {
        title: title,
        height: 100,
        abilityName: '',
        loadingStatus: false
      };
      const item: statusBarManager.StatusBarItem = {
        icons: icons,
        quickOperation: quick,
        hoverTips: hover.length > 0 ? hover : title
      };
      let menuCount = 0;
      if (menuSpec.length > 0) {
        const entries = menuSpec.split(';');
        const menuItems: statusBarManager.StatusBarMenuItem[] = [];
        for (const entry of entries) {
          const trimmed = entry.trim();
          if (trimmed.length === 0) {
            continue;
          }
          const sep = trimmed.indexOf(':');
          const label = sep > 0 ? trimmed.substring(0, sep) : trimmed;
          const code = sep > 0 ? trimmed.substring(sep + 1) : label;
          const menuAction: statusBarManager.StatusBarMenuAction = {
            abilityName: '',
            notifyOnly: true,
            menuCode: code
          };
          const menuItem: statusBarManager.StatusBarMenuItem = {
            title: label,
            menuAction: menuAction,
            menuCode: code
          };
          menuItems.push(menuItem);
        }
        if (menuItems.length > 0) {
          const groups: statusBarManager.StatusBarGroupMenu[] = [menuItems];
          item.statusBarGroupMenu = groups;
          menuCount = menuItems.length;
        }
      }
      this.registerStatusBarEvents();
      statusBarManager.addToStatusBar(this.abilityContext, item);
      this.statusBarAdded = true;
      this.persistStatusBarConfig(title, hover, menuSpec);
      // API 26: device-state gate. When this is false the system accepts the
      // call but shows NOTHING (guide: "如果不支持，则调用addToStatusBar后，界面上无效果").
      let stateSupported = false;
      try {
        stateSupported = await statusBarManager.isStatusBarCapabilitySupported(this.abilityContext);
      } catch (se) {
        hilog.warn(DOMAIN, TAG, 'isStatusBarCapabilitySupported unavailable: %{public}s', this.text(se));
      }
      return '{"ok":true' +
        ',"title":"' + this.esc(title) + '"' +
        ',"hoverTips":"' + this.esc(hover.length > 0 ? hover : title) + '"' +
        ',"menuItems":' + menuCount.toString() +
        ',"syscap":' + (canIUse('SystemCapability.PCService.StatusBarManager') ? 'true' : 'false') +
        ',"deviceStateSupported":' + (stateSupported ? 'true' : 'false') +
        ',"note":"one status-bar icon per app; repeated add is a no-op; deviceStateSupported=false means the icon is registered but invisible"}';
    } catch (err) {
      return '{"ok":false,"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  /** Removes the status-bar icon. Needs a foreground window (system error 1010710004). */
  private statusBarRemove(): Promise<string> {
    try {
      statusBarManager.removeFromStatusBar(this.abilityContext);
      this.statusBarAdded = false;
      this.clearStatusBarConfig();
      return Promise.resolve('{"ok":true,"added":false}');
    } catch (err) {
      return Promise.resolve('{"ok":false,"error":"' + this.esc(this.text(err)) + '"}');
    }
  }

  // —— 状态栏图标配置持久化（2026-10-11 持久化审查修复）——
  // addToStatusBar 的注册是运行时状态，应用重启即丢（实测重启后 added:false）。
  // 与 formId 注册表同族问题：add 时把 {title, hoverTips, menu} 写 preferences，
  // EntryAbility 在 loadContent 完成后调 restoreStatusBar() 自动补挂。

  /** 上次 statusBarAdd 的配置（title/hoverTips/menu），重启后据此补挂。 */
  private persistStatusBarConfig(title: string, hoverTips: string, menu: string): void {
    try {
      const pref = preferences.getPreferencesSync(this.abilityContext, { name: 'dsh_statusbar' });
      pref.putSync('config', JSON.stringify({ title: title, hoverTips: hoverTips, menu: menu } as StatusBarSavedConfig));
      pref.flushSync();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'persistStatusBarConfig failed: %{public}s', this.text(err));
    }
  }

  private clearStatusBarConfig(): void {
    try {
      const pref = preferences.getPreferencesSync(this.abilityContext, { name: 'dsh_statusbar' });
      pref.deleteSync('config');
      pref.flushSync();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'clearStatusBarConfig failed: %{public}s', this.text(err));
    }
  }

  /**
   * 应用启动后补挂状态栏图标（若用户此前 add 过且未 remove）。
   * 由 EntryAbility 在 loadContent 完成后调用（addToStatusBar 需要前台窗口）。
   */
  async restoreStatusBar(): Promise<void> {
    if (this.statusBarAdded) return;
    try {
      const pref = preferences.getPreferencesSync(this.abilityContext, { name: 'dsh_statusbar' });
      const saved = pref.getSync('config', '') as string;
      if (!saved) return;
      const cfg: StatusBarSavedConfig = JSON.parse(saved);
      const args: Record<string, Object> = {};
      args['title'] = cfg.title;
      args['hoverTips'] = cfg.hoverTips;
      args['menu'] = cfg.menu;
      const result = await this.statusBarAdd(args);
      hilog.info(DOMAIN, TAG, 'restoreStatusBar: %{public}s', result);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'restoreStatusBar failed: %{public}s', this.text(err));
    }
  }

  /** Status-bar state + click counters (clicks are also logged to hilog). */
  private statusBarStatus(): Promise<string> {
    const clicks: string[] = [];
    for (const code of this.statusBarMenuClicks) {
      clicks.push('"' + this.esc(code) + '"');
    }
    return Promise.resolve('{"ok":true' +
      ',"added":' + (this.statusBarAdded ? 'true' : 'false') +
      ',"leftClicks":' + this.statusBarLeftClicks.toString() +
      ',"menuClicks":[' + clicks.join(',') + ']' +
      ',"supported":' + (canIUse('SystemCapability.PCService.StatusBarManager') ? 'true' : 'false') + '}');
  }

  /** Registers the click events once; left click also re-opens the DSH shell window. */
  private registerStatusBarEvents(): void {
    if (this.statusBarIconCb === undefined) {
      const cb: Callback<emitter.EventData> = (data: emitter.EventData) => {
        this.statusBarLeftClicks++;
        hilog.info(DOMAIN, TAG, 'statusBarIconClick #%{public}d %{public}s',
          this.statusBarLeftClicks, this.text(data.data));
        this.bringShellToFront();
      };
      this.statusBarIconCb = cb;
      statusBarManager.on('statusBarIconClick', cb);
    }
    if (this.statusBarMenuCb === undefined) {
      const cb: Callback<emitter.EventData> = (data: emitter.EventData) => {
        const code = this.text(data.data);
        this.statusBarMenuClicks.push(code);
        hilog.info(DOMAIN, TAG, 'rightMenuClick %{public}s', code);
      };
      this.statusBarMenuCb = cb;
      statusBarManager.on('rightMenuClick', cb);
    }
  }

  /** Brings the DSH shell window back to the front. */
  private bringShellToFront(): void {
    const want: Want = {
      bundleName: SHELL_BUNDLE_NAME,
      abilityName: SHELL_ABILITY_NAME
    };
    this.abilityContext.startAbility(want).catch((err: Object) => {
      hilog.warn(DOMAIN, TAG, 'bringShellToFront failed: %{public}s', this.text(err));
    });
  }

  // ---------------------------------------------------------------------------
  // Desktop Extension Kit (PC quick bar / 快捷栏)
  // ---------------------------------------------------------------------------

  /** Checks whether the current device state supports the quick bar. */
  private async quickBarStatus(): Promise<string> {
    let supported = false;
    try {
      supported = await quickBarManager.isQuickBarCapabilitySupported(this.abilityContext);
    } catch (err) {
      return '{"ok":false,"error":"' + this.esc(this.text(err)) + '"}';
    }
    return '{"ok":true,"deviceStateSupported":' + (supported ? 'true' : 'false') +
      ',"syscap":' + (canIUse('SystemCapability.PCService.QuickBarManager') ? 'true' : 'false') + '}';
  }

  /**
   * Adds a DSH task to the PC quick bar (creates a "DSH" custom category on
   * first use). args: { taskName?, taskDetail?, abilityName?, moduleName? }
   */
  private async quickBarAdd(args: Record<string, Object>): Promise<string> {
    const nameRaw = this.stringArg(args, 'taskName');
    const taskName = nameRaw.length > 0 ? nameRaw : 'DSH';
    const detail = this.stringArg(args, 'taskDetail');
    const abilityRaw = this.stringArg(args, 'abilityName');
    const ability = abilityRaw.length > 0 ? abilityRaw : SHELL_ABILITY_NAME;
    const moduleRaw = this.stringArg(args, 'moduleName');
    try {
      const supported = await quickBarManager.isQuickBarCapabilitySupported(this.abilityContext);
      if (!supported) {
        return '{"ok":false,"error":"quick bar capability not supported in the current device state"}';
      }
      // getCustomCategories throws "Category not found" while the app owns no
      // category yet — that is the normal first-run state, not an error.
      let categoryId = -1;
      try {
        const cats: quickBarManager.CustomCategory[] =
          await quickBarManager.getCustomCategories(this.abilityContext);
        if (cats.length > 0) {
          categoryId = cats[0].categoryId;
        }
      } catch (le) {
        hilog.info(DOMAIN, TAG, 'quickBarAdd: no category yet (%{public}s)', this.text(le));
      }
      if (categoryId < 0) {
        const created: quickBarManager.CustomCategory =
          await quickBarManager.addCustomCategory(this.abilityContext, 'DSH');
        categoryId = created.categoryId;
      }
      if (categoryId < 0) {
        return '{"ok":false,"error":"could not obtain a quick-bar category id"}';
      }
      const info: quickBarManager.QuickTaskInfo = {
        taskName: taskName,
        abilityName: ability,
        moduleName: moduleRaw.length > 0 ? moduleRaw : 'entry'
      };
      if (detail.length > 0) {
        info.taskDetail = detail;
      }
      const task: quickBarManager.QuickTask =
        await quickBarManager.addQuickTask(this.abilityContext, categoryId, info);
      return '{"ok":true,"categoryId":' + categoryId.toString() +
        ',"taskId":' + task.taskId.toString() +
        ',"taskName":"' + this.esc(taskName) + '"}';
    } catch (err) {
      return '{"ok":false,"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  /** Lists the DSH quick-bar categories and their tasks. */
  private async quickBarList(): Promise<string> {
    try {
      let cats: quickBarManager.CustomCategory[] = [];
      try {
        cats = await quickBarManager.getCustomCategories(this.abilityContext);
      } catch (le) {
        hilog.info(DOMAIN, TAG, 'quickBarList: no category yet (%{public}s)', this.text(le));
      }
      const parts: string[] = [];
      for (const cat of cats) {
        const tasks: quickBarManager.QuickTask[] =
          await quickBarManager.getTasksFromCategory(this.abilityContext, cat.categoryId);
        const tparts: string[] = [];
        for (const task of tasks) {
          tparts.push('{"taskId":' + task.taskId.toString() +
            ',"taskName":"' + this.esc(task.taskInfo.taskName) + '"}');
        }
        parts.push('{"categoryId":' + cat.categoryId.toString() +
          ',"categoryName":"' + this.esc(cat.categoryName) + '"' +
          ',"tasks":[' + tparts.join(',') + ']}');
      }
      return '{"ok":true,"categories":[' + parts.join(',') + ']}';
    } catch (err) {
      return '{"ok":false,"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  /**
   * Drives the quick-bar progress ring. args: { completed?, total?, state? }
   * state: 0 = clear, 1 = normal (default), 2 = paused, 3 = error.
   * Needs ohos.permission.SET_ABILITY_INSTANCE_INFO (declared in module.json5).
   */
  private async quickBarProgress(args: Record<string, Object>): Promise<string> {
    const completed = this.numberArg(args, 'completed');
    const total = this.numberArg(args, 'total');
    const stateNum = this.numberArg(args, 'state');
    try {
      if (total <= 0) {
        await quickBarManager.setProgressState(this.abilityContext,
          quickBarManager.ProgressState.NO_PROGRESS);
        return '{"ok":true,"state":"NO_PROGRESS"}';
      }
      let state: quickBarManager.ProgressState = quickBarManager.ProgressState.NORMAL;
      if (stateNum === 2) {
        state = quickBarManager.ProgressState.PAUSED;
      } else if (stateNum === 3) {
        state = quickBarManager.ProgressState.ERROR;
      }
      await quickBarManager.setProgressState(this.abilityContext, state);
      await quickBarManager.setProgressValue(this.abilityContext, completed, total);
      return '{"ok":true,"completed":' + completed.toString() +
        ',"total":' + total.toString() + ',"state":' + stateNum.toString() + '}';
    } catch (err) {
      return '{"ok":false,"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  // ---------------------------------------------------------------------------
  // On-device model / NLP / TTS probes (DataAugmentationKit, NaturalLanguageKit, CoreSpeechKit)
  // ---------------------------------------------------------------------------

  /**
   * On-device local chat model (DataAugmentationKit). args: { question }
   * Streams chunks and resolves once the model marks the answer finished.
   */
  private async localChat(args: Record<string, Object>): Promise<string> {
    const question = this.stringArg(args, 'question');
    if (question.length === 0) {
      return '{"ok":false,"error":"question is required"}';
    }
    const started = Date.now();
    try {
      const inited: boolean = await localChatModel.init();
      let answer = '';
      let chunks = 0;
      await new Promise<void>((resolve, reject) => {
        const info: localChatModel.QuestionInfo = { questionId: 1, content: question };
        const config: localChatModel.Config = { isStream: true };
        localChatModel.chat(info, config, (err: BusinessError, data: localChatModel.Answer) => {
          if (err) {
            reject(err);
            return;
          }
          chunks++;
          answer += data.content;
          if (data.isFinished) {
            resolve();
          }
        }).catch((pe: Object) => {
          reject(pe);
        });
      });
      return '{"ok":true' +
        ',"inited":' + (inited ? 'true' : 'false') +
        ',"chunks":' + chunks.toString() +
        ',"elapsedMs":' + (Date.now() - started).toString() +
        ',"answer":"' + this.esc(answer) + '"}';
    } catch (err) {
      return '{"ok":false,"elapsedMs":' + (Date.now() - started).toString() +
        ',"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  /** Entity extraction (NaturalLanguageKit). args: { text } */
  private async nlpEntity(args: Record<string, Object>): Promise<string> {
    const text = this.stringArg(args, 'text');
    if (text.length === 0) {
      return '{"ok":false,"error":"text is required"}';
    }
    const started = Date.now();
    try {
      const inited: boolean = await textProcessing.init();
      const entities: textProcessing.Entity[] = await textProcessing.getEntity(text);
      const parts: string[] = [];
      for (const ent of entities) {
        parts.push('{"text":"' + this.esc(ent.text) + '"' +
          ',"type":"' + this.esc(ent.type as string) + '"' +
          ',"offset":' + ent.charOffset.toString() + '}');
      }
      await textProcessing.release();
      return '{"ok":true,"inited":' + (inited ? 'true' : 'false') +
        ',"elapsedMs":' + (Date.now() - started).toString() +
        ',"entities":[' + parts.join(',') + ']}';
    } catch (err) {
      return '{"ok":false,"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  /** Word segmentation (NaturalLanguageKit). args: { text } */
  private async nlpSegment(args: Record<string, Object>): Promise<string> {
    const text = this.stringArg(args, 'text');
    if (text.length === 0) {
      return '{"ok":false,"error":"text is required"}';
    }
    const started = Date.now();
    try {
      await textProcessing.init();
      const words: textProcessing.WordSegment[] = await textProcessing.getWordSegment(text);
      const parts: string[] = [];
      for (const w of words) {
        parts.push('{"word":"' + this.esc(w.word) + '","tag":"' + this.esc(w.wordTag) + '"}');
      }
      await textProcessing.release();
      return '{"ok":true,"elapsedMs":' + (Date.now() - started).toString() +
        ',"words":[' + parts.join(',') + ']}';
    } catch (err) {
      return '{"ok":false,"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  /**
   * Text to speech (CoreSpeechKit). args: { text, language?, person?, online? }
   * online defaults to 1 (cloud voice); 0 uses an already-downloaded offline voice.
   */
  private async ttsSpeak(args: Record<string, Object>): Promise<string> {
    const text = this.stringArg(args, 'text');
    if (text.length === 0) {
      return '{"ok":false,"error":"text is required"}';
    }
    const langRaw = this.stringArg(args, 'language');
    const language = langRaw.length > 0 ? langRaw : 'zh-CN';
    const person = this.numberArg(args, 'person');
    const onlineArg = this.numberArg(args, 'online');
    const online = onlineArg > 0 ? onlineArg : 1;
    const started = Date.now();
    try {
      const params: textToSpeech.CreateEngineParams = {
        language: language,
        person: person,
        online: online
      };
      const engine: textToSpeech.TextToSpeechEngine = await textToSpeech.createEngine(params);
      const requestId = 'dsh-' + Date.now().toString();
      const outcome: string = await new Promise<string>((resolve) => {
        let settled = false;
        const finish = (value: string): void => {
          if (!settled) {
            settled = true;
            resolve(value);
          }
        };
        const listener: textToSpeech.SpeakListener = {
          onStart: (rid: string, response: textToSpeech.StartResponse) => {
            hilog.info(DOMAIN, TAG, 'tts onStart %{public}s', rid);
          },
          onComplete: (rid: string, response: textToSpeech.CompleteResponse) => {
            finish('complete');
          },
          onStop: (rid: string, response: textToSpeech.StopResponse) => {
            finish('stopped');
          },
          onError: (rid: string, errorCode: number, errorMessage: string) => {
            finish('error ' + errorCode.toString() + ' ' + errorMessage);
          }
        };
        engine.setListener(listener);
        engine.speak(text, { requestId: requestId });
        setTimeout(() => {
          finish('timeout');
        }, 20000);
      });
      engine.shutdown();
      return '{"ok":true,"outcome":"' + this.esc(outcome) + '"' +
        ',"language":"' + this.esc(language) + '"' +
        ',"online":' + online.toString() +
        ',"elapsedMs":' + (Date.now() - started).toString() + '}';
    } catch (err) {
      return '{"ok":false,"elapsedMs":' + (Date.now() - started).toString() +
        ',"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  // ---------------------------------------------------------------------------
  // 端侧 embedding（智慧数据平台）—— 语义检索的关键件
  // ---------------------------------------------------------------------------

  /**
   * On-device text embedding. args: { text, full?, npu? }
   * Returns dim + norm + a short preview by default (a 1024-dim vector is noisy
   * in a text channel); pass full=true to get the whole vector.
   */
  private async embedText(args: Record<string, Object>): Promise<string> {
    const text = this.stringArg(args, 'text');
    if (text.length === 0) {
      return '{"ok":false,"error":"text is required"}';
    }
    const wantFull = this.stringArg(args, 'full') === 'true';
    const npu = this.stringArg(args, 'npu') === 'true';
    const started = Date.now();
    try {
      const config: intelligence.ModelConfig = {
        version: intelligence.ModelVersion.BASIC_MODEL,
        isNpuAvailable: npu
      };
      const model: intelligence.TextEmbedding = await intelligence.getTextEmbeddingModel(config);
      await model.loadModel();
      const loadedMs = Date.now() - started;
      const vec: Array<number> = await model.getEmbedding(text);
      let sum = 0;
      for (const v of vec) {
        sum += v * v;
      }
      const norm = Math.sqrt(sum);
      const preview: string[] = [];
      const n = vec.length < 8 ? vec.length : 8;
      for (let i = 0; i < n; i++) {
        preview.push(vec[i].toFixed(6));
      }
      let vectorPart = '';
      if (wantFull) {
        const all: string[] = [];
        for (const v of vec) {
          all.push(v.toFixed(6));
        }
        vectorPart = ',"vector":[' + all.join(',') + ']';
      }
      await model.releaseModel();
      return '{"ok":true' +
        ',"dim":' + vec.length.toString() +
        ',"norm":' + norm.toFixed(6) +
        ',"loadMs":' + loadedMs.toString() +
        ',"elapsedMs":' + (Date.now() - started).toString() +
        ',"npu":' + (npu ? 'true' : 'false') +
        ',"preview":[' + preview.join(',') + ']' +
        vectorPart + '}';
    } catch (err) {
      return '{"ok":false,"elapsedMs":' + (Date.now() - started).toString() +
        ',"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  /**
   * Batch embedding for indexing. args: { texts (newline-separated), npu? }
   * Loads the model ONCE for the whole batch (loadModel is the expensive part),
   * so this is the right call for building an index.
   */
  private async embedBatch(args: Record<string, Object>): Promise<string> {
    const raw = this.stringArg(args, 'texts');
    if (raw.length === 0) {
      return '{"ok":false,"error":"texts is required (newline-separated)"}';
    }
    const npu = this.stringArg(args, 'npu') === 'true';
    const items: string[] = [];
    for (const line of raw.split('\n')) {
      const t = line.trim();
      if (t.length > 0) {
        items.push(t);
      }
    }
    if (items.length === 0) {
      return '{"ok":false,"error":"no non-empty texts"}';
    }
    const started = Date.now();
    try {
      const config: intelligence.ModelConfig = {
        version: intelligence.ModelVersion.BASIC_MODEL,
        isNpuAvailable: npu
      };
      const model: intelligence.TextEmbedding = await intelligence.getTextEmbeddingModel(config);
      await model.loadModel();
      const loadMs = Date.now() - started;
      const parts: string[] = [];
      let dim = 0;
      for (const t of items) {
        const vec: Array<number> = await model.getEmbedding(t);
        dim = vec.length;
        const nums: string[] = [];
        for (const v of vec) {
          nums.push(v.toFixed(6));
        }
        parts.push('[' + nums.join(',') + ']');
      }
      await model.releaseModel();
      return '{"ok":true' +
        ',"count":' + items.length.toString() +
        ',"dim":' + dim.toString() +
        ',"loadMs":' + loadMs.toString() +
        ',"elapsedMs":' + (Date.now() - started).toString() +
        ',"vectors":[' + parts.join(',') + ']}';
    } catch (err) {
      return '{"ok":false,"elapsedMs":' + (Date.now() - started).toString() +
        ',"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  /** Splits text for RAG indexing. args: { text, size?, overlapRatio? } */
  private async splitText(args: Record<string, Object>): Promise<string> {
    const text = this.stringArg(args, 'text');
    if (text.length === 0) {
      return '{"ok":false,"error":"text is required"}';
    }
    const size = this.numberArg(args, 'size') > 0 ? this.numberArg(args, 'size') : 200;
    let overlap = 0.2;
    const raw = this.stringArg(args, 'overlapRatio');
    if (raw.length > 0) {
      const parsed = Number.parseFloat(raw);
      if (!Number.isNaN(parsed)) {
        overlap = parsed;
      }
    }
    try {
      const config: intelligence.SplitConfig = { size: size, overlapRatio: overlap };
      const chunks: Array<string> = await intelligence.splitText(text, config);
      const parts: string[] = [];
      for (const c of chunks) {
        parts.push('"' + this.esc(c) + '"');
      }
      return '{"ok":true,"count":' + chunks.length.toString() +
        ',"chunks":[' + parts.join(',') + ']}';
    } catch (err) {
      return '{"ok":false,"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  // ---------------------------------------------------------------------------
  // 分布式 KV（同应用跨设备，DeviceKVStore）—— 手机/PC 协同的 P0
  // ---------------------------------------------------------------------------

  private kvManager: distributedKVStore.KVManager | undefined = undefined;
  private kvStore: distributedKVStore.SingleKVStore | undefined = undefined;
  private kvStoreId: string = '';

  /** 打开（或创建）分布式 KV。args: { storeId? } —— sync() 需 DISTRIBUTED_DATASYNC。 */
  private async kvOpen(args: Record<string, Object>): Promise<string> {
    const raw = this.stringArg(args, 'storeId');
    const storeId = raw.length > 0 ? raw : 'dsh_kv';
    try {
      const config: distributedKVStore.KVManagerConfig = {
        context: this.abilityContext,
        bundleName: this.abilityContext.abilityInfo.bundleName
      };
      this.kvManager = distributedKVStore.createKVManager(config);
      const options: distributedKVStore.Options = {
        createIfMissing: true,
        encrypt: false,
        backup: false,
        autoSync: true,
        // 2026-10-11 对齐 citemate 实证可用配置（同机同步成功）：SINGLE_VERSION+S3。
        // 原 DEVICE_COLLABORATION+S1 在本机实测触发 IsTrust 拒绝；改后 A/B 验证。
        kvStoreType: distributedKVStore.KVStoreType.SINGLE_VERSION,
        securityLevel: distributedKVStore.SecurityLevel.S3
      };
      this.kvStore = await this.kvManager.getKVStore<distributedKVStore.SingleKVStore>(storeId, options);
      this.kvStoreId = storeId;
      return '{"ok":true,"storeId":"' + this.esc(storeId) + '","type":"SINGLE_VERSION","securityLevel":"S3"}';
    } catch (err) {
      return '{"ok":false,"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  private async ensureKv(): Promise<distributedKVStore.SingleKVStore> {
    if (this.kvStore === undefined) {
      await this.kvOpen({});
    }
    if (this.kvStore === undefined) {
      throw new Error('kv store unavailable');
    }
    return this.kvStore;
  }

  /** 写入一个键。args: { key, value, sync? } */
  private async kvPut(args: Record<string, Object>): Promise<string> {
    const key = this.stringArg(args, 'key');
    const value = this.stringArg(args, 'value');
    if (key.length === 0) {
      return '{"ok":false,"error":"key is required"}';
    }
    try {
      const store = await this.ensureKv();
      await store.put(key, value);
      let synced = false;
      if (this.stringArg(args, 'sync') === 'true') {
        const ids = this.kvDeviceIds(this.stringArg(args, 'deviceIds'));
        await store.sync(ids, distributedKVStore.SyncMode.PUSH_ONLY);
        synced = true;
      }
      return '{"ok":true,"key":"' + this.esc(key) + '","bytes":' + value.length.toString() +
        ',"synced":' + (synced ? 'true' : 'false') + '}';
    } catch (err) {
      return '{"ok":false,"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  /** 读一个键。args: { key } */
  private async kvGet(args: Record<string, Object>): Promise<string> {
    const key = this.stringArg(args, 'key');
    if (key.length === 0) {
      return '{"ok":false,"error":"key is required"}';
    }
    try {
      const store = await this.ensureKv();
      const value = await store.get(key);
      return '{"ok":true,"key":"' + this.esc(key) + '","value":"' + this.esc(this.text(value)) + '"}';
    } catch (err) {
      return '{"ok":false,"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  /** 列出键（可按前缀过滤）。args: { prefix? } */
  private async kvList(args: Record<string, Object>): Promise<string> {
    const prefix = this.stringArg(args, 'prefix');
    try {
      const store = await this.ensureKv();
      const entries: distributedKVStore.Entry[] = await store.getEntries(prefix);
      const parts: string[] = [];
      for (const e of entries) {
        parts.push('{"key":"' + this.esc(e.key) + '","value":"' + this.esc(this.text(e.value)) + '"}');
      }
      return '{"ok":true,"storeId":"' + this.esc(this.kvStoreId) + '","count":' + entries.length.toString() +
        ',"entries":[' + parts.join(',') + ']}';
    } catch (err) {
      return '{"ok":false,"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  /** 与已组网的同应用设备做一次推拉同步。 */
  private async kvSync(args: Record<string, Object>): Promise<string> {
    try {
      const store = await this.ensureKv();
      const ids = this.kvDeviceIds(this.stringArg(args, 'deviceIds'));
      await store.sync(ids, distributedKVStore.SyncMode.PUSH_PULL);
      return '{"ok":true,"storeId":"' + this.esc(this.kvStoreId) +
        '","mode":"PUSH_PULL","devices":' + ids.length.toString() + '}';
    } catch (err) {
      return '{"ok":false,"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  /**
   * sync() 的 deviceIds 必须是真实设备列表（空数组会被拒：params deviceIdList must be array）。
   * 传了逗号分隔的 deviceIds 就用它，否则取当前组网设备的 networkId。
   */
  private kvDeviceIds(raw: string): string[] {
    const ids: string[] = [];
    if (raw.length > 0) {
      for (const piece of raw.split(',')) {
        const t = piece.trim();
        if (t.length > 0) {
          ids.push(t);
        }
      }
      return ids;
    }
    try {
      const dm: distributedDeviceManager.DeviceManager =
        distributedDeviceManager.createDeviceManager(this.abilityContext.abilityInfo.bundleName);
      const list: distributedDeviceManager.DeviceBasicInfo[] = dm.getAvailableDeviceListSync();
      for (const d of list) {
        if (d.networkId !== undefined) {
          ids.push(d.networkId);
        }
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'kvDeviceIds: %{public}s', this.text(err));
    }
    return ids;
  }

  // ---------------------------------------------------------------------------
  // ArkTS 原生 WebSocket 服务端（替代手写 RFC6455 的 ws-server.mjs）
  // ---------------------------------------------------------------------------

  private wsServer: webSocket.WebSocketServer | undefined = undefined;
  private wsClients: webSocket.WebSocketConnection[] = [];
  private wsPort: number = 0;

  /** 启动 WS 服务端。args: { port? } 收到消息会转成桥事件 wsMessage。 */
  private async wsServerStart(args: Record<string, Object>): Promise<string> {
    const rawPort = this.numberArg(args, 'port');
    const port = rawPort > 0 ? rawPort : 18765;
    if (this.wsServer !== undefined) {
      return '{"ok":true,"already":true,"port":' + this.wsPort.toString() +
        ',"clients":' + this.wsClients.length.toString() + '}';
    }
    try {
      const server: webSocket.WebSocketServer = webSocket.createWebSocketServer();
      server.on('connect', (conn: webSocket.WebSocketConnection) => {
        this.wsClients.push(conn);
        hilog.info(DOMAIN, TAG, 'ws connect, clients=%{public}d', this.wsClients.length);
        this.postBridgeEvent('wsConnect', '{"clients":' + this.wsClients.length.toString() + '}');
      });
      server.on('messageReceive', (msg: webSocket.WebSocketMessage) => {
        const text = typeof msg.data === 'string' ? msg.data as string : '';
        hilog.info(DOMAIN, TAG, 'ws message %{public}d bytes', text.length);
        this.postBridgeEvent('wsMessage', JSON.stringify({ text: text }));
      });
      server.on('close', (conn: webSocket.WebSocketConnection, reason: webSocket.CloseResult) => {
        // 连接对象身份不保证可比较，直接用服务端的权威列表重同步，避免计数漂移
        try {
          this.wsClients = server.listAllConnections();
        } catch (ce) {
          const idx = this.wsClients.indexOf(conn);
          if (idx >= 0) {
            this.wsClients.splice(idx, 1);
          }
        }
        this.postBridgeEvent('wsClose', '{"clients":' + this.wsClients.length.toString() + '}');
      });
      server.on('error', (err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'ws server error: %{public}s', this.text(err));
      });
      const config: webSocket.WebSocketServerConfig = {
        serverPort: port,
        maxConcurrentClientsNumber: 8,
        maxConnectionsForOneClient: 4
      };
      const ok: boolean = await server.start(config);
      this.wsServer = server;
      this.wsPort = port;
      return '{"ok":true,"port":' + port.toString() + ',"started":' + (ok ? 'true' : 'false') + '}';
    } catch (err) {
      this.wsServer = undefined;
      return '{"ok":false,"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  private async wsServerStop(): Promise<string> {
    if (this.wsServer === undefined) {
      return '{"ok":true,"already":true}';
    }
    try {
      await this.wsServer.stop();
      this.wsServer = undefined;
      this.wsClients = [];
      return '{"ok":true,"stopped":true}';
    } catch (err) {
      return '{"ok":false,"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  /** 向所有已连接客户端广播。args: { text } */
  private async wsServerSend(args: Record<string, Object>): Promise<string> {
    const text = this.stringArg(args, 'text');
    if (this.wsServer === undefined) {
      return '{"ok":false,"error":"ws server not running"}';
    }
    let sent = 0;
    for (const conn of this.wsClients) {
      try {
        await this.wsServer.send(text, conn);
        sent++;
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'ws send failed: %{public}s', this.text(err));
      }
    }
    return '{"ok":true,"sent":' + sent.toString() + ',"clients":' + this.wsClients.length.toString() + '}';
  }

  private wsServerStatus(): Promise<string> {
    return Promise.resolve('{"ok":true' +
      ',"running":' + (this.wsServer !== undefined ? 'true' : 'false') +
      ',"port":' + this.wsPort.toString() +
      ',"clients":' + this.wsClients.length.toString() +
      ',"syscap":' + (canIUse('SystemCapability.Communication.NetStack') ? 'true' : 'false') + '}');
  }

  /** 把 ArkTS 侧发生的事回写 node（桥 /event → /ui-events）。 */
  private postBridgeEvent(event: string, dataJson: string): void {
    const request = http.createHttp();
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: { 'Content-Type': 'application/json' },
      extraData: '{"event":"' + event + '","data":' + dataJson + '}',
      connectTimeout: 2000,
      readTimeout: 3000
    };
    request.request('http://127.0.0.1:3131/event', options).then(() => {
      request.destroy();
    }).catch((err: Object) => {
      hilog.warn(DOMAIN, TAG, 'postBridgeEvent(%{public}s) failed: %{public}s', event, this.text(err));
      request.destroy();
    });
  }

  // ---------------------------------------------------------------------------
  // 系统分享（systemShare，零权限）—— DSH 产出物一键进系统分享面板
  // ---------------------------------------------------------------------------

  /** 打开系统分享面板。args: { text, title? } —— 需应用在前台（UI 操作）。 */
  private async shareShow(args: Record<string, Object>): Promise<string> {
    const text = this.stringArg(args, 'text');
    if (text.length === 0) {
      return '{"ok":false,"error":"text is required"}';
    }
    const titleRaw = this.stringArg(args, 'title');
    const title = titleRaw.length > 0 ? titleRaw : '来自 DSH';
    try {
      const record: systemShare.SharedRecord = {
        utd: 'general.plain-text',
        content: text,
        title: title
      };
      const data: systemShare.SharedData = new systemShare.SharedData(record);
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      const options: systemShare.ShareControllerOptions = {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DEFAULT
      };
      await controller.show(this.abilityContext, options);
      return '{"ok":true,"records":' + data.getRecords().length.toString() +
        ',"chars":' + text.length.toString() + '}';
    } catch (err) {
      return '{"ok":false,"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  // ---------------------------------------------------------------------------
  // 跨设备 Ability 会话（abilityConnectionManager）—— 绕开 TCP 可达性问题的协同通道
  // ---------------------------------------------------------------------------

  private acsSessionIds: number[] = [];

  /**
   * 建会话（不连接）。args: { deviceId, bundleName?, moduleName?, abilityName?, serviceName? }
   * 对端（手机）必须实现 DistributedExtensionAbility 且 onCollaborate 返回 ACCEPT。
   */
  private acsCreate(args: Record<string, Object>): Promise<string> {
    const deviceId = this.stringArg(args, 'deviceId');
    if (deviceId.length === 0) {
      return Promise.resolve('{"ok":false,"error":"deviceId is required (from listDistributedDevices)"}');
    }
    const bundleRaw = this.stringArg(args, 'bundleName');
    const moduleRaw = this.stringArg(args, 'moduleName');
    const abilityRaw = this.stringArg(args, 'abilityName');
    const serviceRaw = this.stringArg(args, 'serviceName');
    const serviceName = serviceRaw.length > 0 ? serviceRaw : 'dsh_session';
    try {
      const peer: abilityConnectionManager.PeerInfo = {
        deviceId: deviceId,
        bundleName: bundleRaw.length > 0 ? bundleRaw : 'com.example.dshdesktop',
        moduleName: moduleRaw.length > 0 ? moduleRaw : 'entry',
        abilityName: abilityRaw.length > 0 ? abilityRaw : 'DshDistributedAbility'
      };
      const options: abilityConnectionManager.ConnectOptions = { needSendData: true };
      const sessionId: number = abilityConnectionManager.createAbilityConnectionSession(
        serviceName, this.abilityContext, peer, options);
      if (this.acsSessionIds.indexOf(sessionId) < 0) {
        this.acsSessionIds.push(sessionId);
      }
      abilityConnectionManager.on('connect', sessionId, (info: abilityConnectionManager.EventCallbackInfo) => {
        this.postBridgeEvent('acsConnect', '{"sessionId":' + sessionId.toString() + '}');
      });
      abilityConnectionManager.on('disconnect', sessionId, (info: abilityConnectionManager.EventCallbackInfo) => {
        this.postBridgeEvent('acsDisconnect', '{"sessionId":' + sessionId.toString() +
          ',"reason":' + (info.reason !== undefined ? info.reason.toString() : '-1') + '}');
      });
      abilityConnectionManager.on('receiveMessage', sessionId, (info: abilityConnectionManager.EventCallbackInfo) => {
        this.postBridgeEvent('acsMessage', JSON.stringify({ sessionId: sessionId, msg: info.msg ?? '' }));
      });
      abilityConnectionManager.on('receiveData', sessionId, (info: abilityConnectionManager.EventCallbackInfo) => {
        const len = info.data !== undefined ? info.data.byteLength : 0;
        this.postBridgeEvent('acsData', '{"sessionId":' + sessionId.toString() + ',"bytes":' + len.toString() + '}');
      });
      return Promise.resolve('{"ok":true,"sessionId":' + sessionId.toString() +
        ',"serviceName":"' + this.esc(serviceName) + '"' +
        ',"peer":{"deviceId":"' + this.esc(deviceId) + '"' +
        ',"bundleName":"' + this.esc(peer.bundleName) + '"' +
        ',"abilityName":"' + this.esc(peer.abilityName) + '"}}');
    } catch (err) {
      return Promise.resolve('{"ok":false,"error":"' + this.esc(this.text(err)) + '"}');
    }
  }

  /** 发起连接。args: { sessionId } */
  private async acsConnect(args: Record<string, Object>): Promise<string> {
    const sessionId = this.numberArg(args, 'sessionId');
    if (sessionId <= 0) {
      return '{"ok":false,"error":"sessionId is required"}';
    }
    try {
      const result: abilityConnectionManager.ConnectResult = await abilityConnectionManager.connect(sessionId);
      return '{"ok":true,"sessionId":' + sessionId.toString() +
        ',"isConnected":' + (result.isConnected ? 'true' : 'false') +
        ',"errorCode":' + (result.errorCode !== undefined ? result.errorCode.toString() : '-1') +
        ',"reason":"' + this.esc(result.reason ?? '') + '"}';
    } catch (err) {
      return '{"ok":false,"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  /** 发一条文本消息。args: { sessionId, text } */
  private async acsSend(args: Record<string, Object>): Promise<string> {
    const sessionId = this.numberArg(args, 'sessionId');
    const text = this.stringArg(args, 'text');
    try {
      await abilityConnectionManager.sendMessage(sessionId, text);
      return '{"ok":true,"sessionId":' + sessionId.toString() + ',"chars":' + text.length.toString() + '}';
    } catch (err) {
      return '{"ok":false,"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  /** 销毁会话。args: { sessionId } */
  private acsDestroy(args: Record<string, Object>): Promise<string> {
    const sessionId = this.numberArg(args, 'sessionId');
    try {
      abilityConnectionManager.destroyAbilityConnectionSession(sessionId);
      const idx = this.acsSessionIds.indexOf(sessionId);
      if (idx >= 0) {
        this.acsSessionIds.splice(idx, 1);
      }
      return Promise.resolve('{"ok":true,"sessionId":' + sessionId.toString() + '}');
    } catch (err) {
      return Promise.resolve('{"ok":false,"error":"' + this.esc(this.text(err)) + '"}');
    }
  }

  private acsStatus(): Promise<string> {
    const ids: string[] = [];
    for (const id of this.acsSessionIds) {
      ids.push(id.toString());
    }
    return Promise.resolve('{"ok":true,"sessions":[' + ids.join(',') + ']' +
      ',"count":' + this.acsSessionIds.length.toString() +
      ',"syscap":' + (canIUse('SystemCapability.DistributedSched.AppCollaboration') ? 'true' : 'false') + '}');
  }

  /** Minimal standard-alphabet base64 encoder (ArkTS has no Buffer). */
  private base64(bytes: Uint8Array): string {
    // 手搓逐字节拼接在 8MB 文件上会卡死 agent 主线程（O(n²) 实测复现）；
    // util.Base64Helper 是原生实现，8MB 毫秒级。
    return new util.Base64Helper().encodeToStringSync(bytes);
  }

  /**
   * Requests ohos.permission.CUSTOM_SCREEN_CAPTURE (user_grant, availableLevel
   * normal) and reports the outcome.
   *
   * listMainWindows() / snapshotWindow() are the only two actions that need it.
   * The first call makes the system show the grant dialog; until the user
   * accepts, those actions fail with 201 (permission denied). Callers can drive
   * this explicitly instead of relying on a surprise dialog mid-task.
   */
  private async requestScreenCapture(): Promise<string> {
    const perm: Permissions = 'ohos.permission.CUSTOM_SCREEN_CAPTURE';
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const result: PermissionRequestResult =
        await atManager.requestPermissionsFromUser(this.abilityContext, [perm]);
      const codes: string[] = [];
      for (let i = 0; i < result.authResults.length; i++) {
        codes.push(result.authResults[i].toString());
      }
      let granted = false;
      for (let i = 0; i < result.authResults.length; i++) {
        if (result.authResults[i] === 0) {
          granted = true;
        }
      }
      return '{"ok":true,"granted":' + (granted ? 'true' : 'false') +
        ',"authResults":[' + codes.join(',') + ']}';
    } catch (err) {
      throw new Error('requestScreenCapture: ' + this.text(err));
    }
  }

  /** Every display attached to the machine. */
  private async listDisplays(): Promise<string> {
    try {
      const all: Array<display.Display> = await display.getAllDisplays();      const parts: string[] = [];
      for (let i = 0; i < all.length; i++) {
        const d = all[i];
        parts.push('{"id":' + d.id.toString() +
          ',"name":"' + this.esc(d.name) + '"' +
          ',"width":' + d.width.toString() +
          ',"height":' + d.height.toString() +
          ',"densityDPI":' + d.densityDPI.toString() +
          ',"densityPixels":' + d.densityPixels.toString() +
          ',"refreshRate":' + d.refreshRate.toString() + '}');
      }
      return '{"ok":true,"count":' + all.length.toString() +
        ',"displays":[' + parts.join(',') + ']}';
    } catch (err) {
      throw new Error('listDisplays: ' + this.text(err));
    }
  }


  /**
   * Push data to the DSH service card (负一屏 / 桌面卡片).
   *
   * The card UI (pages/DshCard.ets) reads keys: taskStatus, taskTitle,
   * taskDetail, updatedAt, runningCount. Any subset may be sent; missing
   * keys keep their previous values because FormBindingData merges.
   *
   * Requires an active card instance — the user must have pinned the card
   * first. If no card exists the call is a no-op (returns cardFound:false).
   */
  private async updateCard(args: Record<string, Object>): Promise<string> {
    const formId = this.stringArg(args, 'formId');
    const data = new Map<string, Object>();
    // Copy known card keys from args into the binding data payload.
    const keys = ['taskStatus', 'taskTitle', 'taskDetail', 'updatedAt', 'runningCount',
      'tasks', 'rounds', 'steps', 'tokRate', 'tokTotal', 'cacheRate', 'progress'];
    for (const key of keys) {
      const value = args[key];
      if (value !== undefined && value !== null) {
        data.set(key, value);
      }
    }
    if (data.size === 0) {
      throw new Error('updateCard: at least one of ' + keys.join('/') + ' is required');
    }
    if (formId.length > 0) {
      DshFormAbility.updateCardData(this.abilityContext, formId, data);
      return '{"updated":true,"formId":"' + formId + '"}';
    }
    // No formId given — broadcast to every active card for this bundle.
    // getPublishedRunningFormInfos() needs privileges we do not have (fails
    // with 16500100 "Failed to obtain the configuration information");
    // getFormsInfo() lists this app's own widgets with zero extra permission
    // (FormInfo.formId since API 20).
    // FormInfo 没有 formId（formId 只在 RunningFormInfo 上），而设备级枚举
    // getPublishedRunningFormInfos() 三方调用报 16500100 —— 所以用
    // DshFormAbility 在 onAddForm 里记下的 formId 列表（零权限、可靠）。
    // 先尝试从 preferences 恢复（form 进程写、主进程读，应用重启不丢）。
    DshFormAbility.restoreFormIds(this.abilityContext);
    const ids: string[] = DshFormAbility.knownFormIds();
    if (ids.length === 0) {
      // knownFormIds 是进程内注册表：应用重启后被清空，但桌面已钉的卡片还在
      // → 回退到零权限的 getFormsInfo()（2026-10-11 17:33 经此路径实测更新
      // 3 张卡片）。注意 FormInfo 的类型声明里没有 formId（只有
      // RunningFormInfo 有），但运行时对象实际携带 → 用显式子接口取。
      interface FormInfoWithId extends formInfo.FormInfo {
        formId?: string;
      }
      try {
        const forms = (await formProvider.getFormsInfo()) as FormInfoWithId[];
        let n = 0;
        for (const f of forms) {
          if (typeof f.formId === 'string' && f.formId.length > 0) {
            DshFormAbility.updateCardData(this.abilityContext, f.formId, data);
            n++;
          }
        }
        if (n > 0) {
          return '{"updated":true,"cards":' + n.toString() + ',"via":"getFormsInfo-fallback"}';
        }
      } catch (fallbackErr) {
        hilog.error(DOMAIN, 'testTag', 'updateCard getFormsInfo fallback failed: %{public}s', JSON.stringify(fallbackErr));
      }
      return '{"updated":false,"cards":0,"reason":"no card has been added yet (onAddForm not called)"}';
    }
    let updated = 0;
    for (const id of ids) {
      try {
        DshFormAbility.updateCardData(this.abilityContext, id, data);
        updated++;
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'updateCardData(%{public}s) failed: %{public}s', id, this.text(err));
      }
    }
    return '{"updated":true,"cards":' + updated.toString() + '}';
  }

  /**
   * Publishes only work when the app is allowed to notify. The first call may
   * raise the system authorization prompt; the answer is reported back so the
   * caller knows whether the user needs to fix it in Settings.
   */
  private async ensureNotificationsEnabled(): Promise<boolean> {
    try {
      if (await notificationManager.isNotificationEnabled()) {
        return true;
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'isNotificationEnabled failed: %{public}s', this.text(err));
    }
    try {
      await notificationManager.requestEnableNotification(this.abilityContext);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'requestEnableNotification failed: %{public}s', this.text(err));
      return false;
    }
    try {
      return await notificationManager.isNotificationEnabled();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'notification state re-check failed: %{public}s', this.text(err));
      return false;
    }
  }

  private buildNotificationWantAgent(id: number): Promise<WantAgent> {
    const want: Want = {
      bundleName: SHELL_BUNDLE_NAME,
      abilityName: SHELL_ABILITY_NAME
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [want],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: id,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return wantAgent.getWantAgent(info);
  }

  /**
   * Builds the action buttons for a notification from `args.buttons`.
   *
   * Each button fires SEND_COMMON_EVENT (silent, in-app) carrying
   * `{ dshNotifyId, dshButtonId }`; `subscribeNotificationActions` picks that
   * up and relays it to the node side. Malformed entries are skipped rather
   * than failing the whole notification — a missing button must never cost the
   * user the message itself.
   */
  private async buildNotificationButtons(
    args: Record<string, Object>, id: number
  ): Promise<Array<notificationManager.NotificationActionButton>> {
    const raw = args.buttons;
    const out: Array<notificationManager.NotificationActionButton> = [];
    if (!Array.isArray(raw)) {
      return out;
    }
    const specs = raw as Array<Object>;
    // Session that sent this notification, echoed back on every button press so
    // the node side can wake exactly that session (the event carries only
    // notifyId/buttonId otherwise).
    const rawSession = args.buttonsSessionId;
    const senderSession = typeof rawSession === 'string' ? rawSession as string : '';
    for (let i = 0; i < specs.length && out.length < NOTIFY_MAX_BUTTONS; i++) {
      const item = specs[i];
      if (item === undefined || item === null || typeof item !== 'object') {
        continue;
      }
      const spec = item as Record<string, Object>;
      const buttonId = typeof spec.id === 'string' ? spec.id as string : '';
      const title = typeof spec.title === 'string' ? spec.title as string : '';
      if (buttonId.length === 0 || title.length === 0) {
        continue;
      }
      try {
        // SEND_COMMON_EVENT contract (API 9+): the common-event NAME is carried
        // by `Want.action`, and the payload by `Want.parameters`. An empty
        // `action` means the system has no event to publish, so the button
        // silently does nothing — observed 2026-10-10, and the reason the
        // subscriber saw zero events despite subscribing successfully.
        // bundleName/abilityName are deliberately NOT set: this is a broadcast,
        // not an ability launch.
        const want: Want = {
          action: NOTIFY_ACTION_EVENT,
          parameters: { dshNotifyId: id, dshButtonId: buttonId, dshSessionId: senderSession }
        };
        const info: wantAgent.WantAgentInfo = {
          wants: [want],
          actionType: wantAgent.OperationType.SEND_COMMON_EVENT,
          requestCode: id * 10 + i,
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        };
        const agent = await wantAgent.getWantAgent(info);
        out.push({ title: title, wantAgent: agent, extras: { buttonId: buttonId } });
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'button "%{public}s" skipped: %{public}s',
          buttonId, this.text(err));
      }
    }
    return out;
  }

  /**
   * Subscribes once to NOTIFY_ACTION_EVENT so button presses reach the node side.
   *
   * Idempotent: repeated calls are no-ops. Failure is non-fatal — buttons then
   * simply do nothing, and the notification still arrives.
   */
  async subscribeNotificationActions(): Promise<string> {
    if (this.actionSubscriber !== undefined) {
      return '{"subscribed":true,"already":true}';
    }
    try {
      const info: commonEventManager.CommonEventSubscribeInfo = { events: [NOTIFY_ACTION_EVENT] };
      const subscriber = await commonEventManager.createSubscriber(info);
      const cb = (data: commonEventManager.CommonEventData): void => {
        // ArkTS bans `any`/`unknown` locals: keep the probe values explicitly
        // typed and validate with typeof rather than leaning on undefined.
        const params: Record<string, Object> | undefined = data.parameters;
        let notifyId: number = 0;
        let buttonId: string = '';
        let sessionId: string = '';
        if (params !== undefined) {
          const rawId: Object = params.dshNotifyId;
          const rawButton: Object = params.dshButtonId;
          const rawSession: Object = params.dshSessionId;
          if (typeof rawId === 'number') {
            notifyId = rawId as number;
          }
          if (typeof rawButton === 'string') {
            buttonId = rawButton as string;
          }
          if (typeof rawSession === 'string') {
            sessionId = rawSession as string;
          }
        }
        const payload = new Map<string, Object>();
        payload.set('notifyId', notifyId);
        payload.set('buttonId', buttonId);
        payload.set('sessionId', sessionId);
        this.sendEvent('notificationButton', payload);
      };
      await commonEventManager.subscribeToEvent(subscriber, cb);
      this.actionSubscriber = subscriber;
      hilog.info(DOMAIN, TAG, 'notification action subscriber ready');
      return '{"subscribed":true,"already":false}';
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'notification action subscribe failed: %{public}s', this.text(err));
      return '{"subscribed":false,"error":"' + this.text(err).replace(/"/g, '\'') + '"}';
    }
  }

  private notificationId(args: Record<string, Object>): number {
    const provided = this.numberArg(args, 'id');
    if (provided > 0) {
      return provided;
    }
    this.notificationSeq += 1;
    return NOTIFY_ID_BASE + (this.notificationSeq % NOTIFY_ID_SPAN);
  }

  /** 读取布尔参数；缺省返回 false。 */
  private booleanArg(args: Record<string, Object>, key: string): boolean {
    const value = args[key];
    return typeof value === 'boolean' ? value as boolean : false;
  }

  private numberArg(args: Record<string, Object>, key: string): number {
    const value = args[key];
    if (typeof value === 'number') {
      return value as number;
    }
    return 0;
  }

  private request(path: string, method: http.RequestMethod, body: string, readTimeoutMs: number): Promise<HttpReply> {
    return new Promise<HttpReply>((resolve) => {
      const request = http.createHttp();
      // Single literal in the canonical HttpRequestOptions shape: ArkTS is
      // happiest when object literals match a declared interface up front.
      const options: http.HttpRequestOptions = {
        method: method,
        connectTimeout: 3000,
        readTimeout: readTimeoutMs,
        header: { 'Content-Type': 'application/json' },
        extraData: body
      };
      request.request(this.baseUrl + path, options).then((response: http.HttpResponse) => {
        const text = typeof response.result === 'string' ? response.result : '';
        resolve({ code: response.responseCode, body: text });
        request.destroy();
      }).catch((err: Object) => {
        // Connection refused while the node side is not up: code 0 = retry.
        resolve({ code: 0, body: '' });
        request.destroy();
      });
    });
  }

  private stringArg(args: Record<string, Object>, key: string): string {
    const value = args[key];
    if (typeof value === 'string') {
      return value as string;
    }
    return '';
  }

  private text(value: Object | undefined): string {
    if (value === undefined) {
      return '';
    }
    if (value instanceof Error) {
      return (value as Error).message;
    }
    if (typeof value === 'string') {
      return value as string;
    }
    return JSON.stringify(value);
  }

  // ---------------------------------------------------------------------------
  // collabProbe（2026-10-12 追加）：abilityConnectionManager 全链路探针。
  // 与 acs* 系列的区别：ConnectOptions 显式补齐 needSendStream/needReceiveStream/
  // needSendBigData —— 10-12 实测只给 needSendData 时 connect 能 isConnected:true，
  // 但 sendMessage 报 401「message channel not exit」（native 层 unwrap 缺这几个字段）。
  // args: { deviceId, abilityName?, text? }，一次完成 create→connect→sendMessage。
  // ---------------------------------------------------------------------------

  private async collabProbe(args: Record<string, Object>): Promise<string> {
    const deviceId = this.stringArg(args, 'deviceId');
    if (deviceId.length === 0) {
      return '{"ok":false,"error":"deviceId is required (from listDistributedDevices)"}';
    }
    const abilityRaw = this.stringArg(args, 'abilityName');
    const textRaw = this.stringArg(args, 'text');
    const msgText = textRaw.length > 0 ? textRaw : 'collabProbe-ping';
    try {
      const peer: abilityConnectionManager.PeerInfo = {
        deviceId: deviceId,
        bundleName: 'com.example.dshdesktop',
        moduleName: 'entry',
        abilityName: abilityRaw.length > 0 ? abilityRaw : 'EntryAbility'
      };
      const options = {
        needSendData: true,
        needSendStream: false,
        needReceiveStream: false,
        needSendBigData: true
      } as abilityConnectionManager.ConnectOptions;
      const sessionId: number = abilityConnectionManager.createAbilityConnectionSession(
        'dsh_session', this.abilityContext, peer, options);
      abilityConnectionManager.on('receiveMessage', sessionId,
        (info: abilityConnectionManager.EventCallbackInfo) => {
          this.postBridgeEvent('collabProbeMsg',
            JSON.stringify({ sessionId: sessionId, msg: info.msg ?? '' }));
        });
      const result: abilityConnectionManager.ConnectResult =
        await abilityConnectionManager.connect(sessionId);
      if (!result.isConnected) {
        return '{"ok":true,"stage":"connect","isConnected":false,"errorCode":' +
          (result.errorCode !== undefined ? result.errorCode.toString() : '-1') +
          ',"reason":"' + this.esc(result.reason ?? '') + '","sessionId":' + sessionId.toString() + '}';
      }
      // 等消息通道就绪
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => {
          resolve();
        }, 2000);
      });
      let sendResult = '';
      try {
        await abilityConnectionManager.sendMessage(sessionId, msgText);
        sendResult = 'ok';
      } catch (sendErr) {
        sendResult = this.text(sendErr);
      }
      return '{"ok":true,"stage":"send","isConnected":true,"sessionId":' + sessionId.toString() +
        ',"send":"' + this.esc(sendResult) + '","msg":"' + this.esc(msgText) + '"}';
    } catch (err) {
      return '{"ok":false,"error":"' + this.esc(this.text(err)) + '"}';
    }
  }

  // collabNotify（2026-10-12）：WS 通道零客户端时的原生兜底通知。
  // 链路：mobile-bridge /notify（hub.size===0）→ 桥 collabNotify → collab 会话
  // sendMessage(JSON) → 手机壳 EntryAbility.receiveMessage → 系统通知。
  // args: { deviceId?, title, body, level? }；deviceId 缺省取第一个在线可信设备。
  // ---------------------------------------------------------------------------
  private async collabNotify(args: Record<string, Object>): Promise<string> {
    const title = this.stringArg(args, 'title');
    const body = this.stringArg(args, 'body');
    const level = this.stringArg(args, 'level');
    let deviceId = this.stringArg(args, 'deviceId');
    if (deviceId.length === 0) {
      try {
        const dm: distributedDeviceManager.DeviceManager =
          distributedDeviceManager.createDeviceManager(this.abilityContext.abilityInfo.bundleName);
        const list: distributedDeviceManager.DeviceBasicInfo[] = dm.getAvailableDeviceListSync();
        if (list.length > 0) {
          deviceId = list[0].deviceId;
        }
      } catch (e) {
        return '{"ok":false,"error":"device list failed: ' + this.esc(this.text(e)) + '"}';
      }
    }
    if (deviceId.length === 0) {
      return '{"ok":false,"error":"no available trusted device"}';
    }
    const payload: string = JSON.stringify({
      type: 'notify',
      title: title.length > 0 ? title : 'DSH',
      body: body,
      level: level.length > 0 ? level : 'info',
      ts: Date.now(),
      from: 'collab'
    });
    let sessionId = -1;
    try {
      const peer: abilityConnectionManager.PeerInfo = {
        deviceId: deviceId,
        bundleName: 'com.example.dshdesktop',
        moduleName: 'entry',
        abilityName: 'EntryAbility'
      };
      const options = {
        needSendData: true,
        needSendStream: false,
        needReceiveStream: false,
        needSendBigData: true
      } as abilityConnectionManager.ConnectOptions;
      sessionId = abilityConnectionManager.createAbilityConnectionSession(
        'dsh_session', this.abilityContext, peer, options);
      const result: abilityConnectionManager.ConnectResult =
        await abilityConnectionManager.connect(sessionId);
      if (!result.isConnected) {
        return '{"ok":false,"stage":"connect","errorCode":' +
          (result.errorCode !== undefined ? result.errorCode.toString() : '-1') +
          ',"reason":"' + this.esc(result.reason ?? '') + '"}';
      }
      // 等消息通道就绪（同 collabProbe 实测值）
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => {
          resolve();
        }, 2000);
      });
      await abilityConnectionManager.sendMessage(sessionId, payload);
      return '{"ok":true,"via":"collab","sessionId":' + sessionId.toString() + '}';
    } catch (err) {
      return '{"ok":false,"error":"' + this.esc(this.text(err)) + '"}';
    } finally {
      if (sessionId >= 0) {
        try {
          abilityConnectionManager.disconnect(sessionId);
          abilityConnectionManager.destroyAbilityConnectionSession(sessionId);
        } catch { /* 会话可能已塌，忽略 */ }
      }
    }
  }
}

/** Offscreen-render demo builder for the offscreenRender bridge action. */
@Builder
function DshOffscreenCard(text: string) {
  Column() {
    Text(text)
      .fontSize(32)
      .fontColor(Color.White)
      .margin(12)
    Text(new Date().toLocaleString())
      .fontSize(18)
      .fontColor(Color.Gray)
  }
  .padding(24)
  .backgroundColor('#FF1A73E8')
  .borderRadius(16)
}
