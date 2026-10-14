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
 * 系统事件常驻监听器 —— 事件驱动自动化的基础设施。
 *
 * 与 commonEventProbe 的区别：
 *   - probe 是「订阅 → 等 N 毫秒 → 返回」的一次性探测（阻塞式）
 *   - watcher 是「常驻订阅 → 持续累积 → 随时查询」的后台监听（非阻塞）
 *
 * 权限：ohos.permission.COMMONEVENT_STICKY（normal 级 + system_grant，已授予，无需 ACL）
 *
 * 这也是 DSH「事件驱动自动化」的底座：不再只能轮询，而是系统状态变化时主动触发。
 * 见 skill: harmonyos-pc-control/reference/events.md §二·六
 */

import commonEventManager from '@ohos.commonEventManager';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'DshEventWatcher';

/** 实测可收到的事件（时间戳 + 事件名 + code）。 */
export interface WatchedEvent {
  at: number;
  event: string;
  code: number;
}

/**
 * 默认监听的事件集。
 * 注意：只有系统真的发布的公共事件才收得到；应用启停/前后台不走这里（用 hisysevent）。
 * 已实测可收到：SCREEN_ON/OFF、CONNECTIVITY_CHANGE、TIME_TICK。
 */
const DEFAULT_EVENTS: string[] = [
  'usual.event.SCREEN_ON',
  'usual.event.SCREEN_OFF',
  'usual.event.CONNECTIVITY_CHANGE',
  'usual.event.AIRPLANE_MODE',
  'usual.event.BATTERY_CHANGED',
  'usual.event.POWER_SAVE_MODE_CHANGED',
  'usual.event.PACKAGE_ADDED',
  'usual.event.PACKAGE_REMOVED',
  'usual.event.USER_UNLOCKED',
  'usual.event.TIME_SET',
  'usual.event.TIMEZONE_CHANGED',
  'usual.event.LOCALE_CHANGED'
];

/** 常驻事件监听器：订阅一次，持续累积事件，支持随时查询与清空。 */
export class SystemEventWatcher {
  private subscriber?: commonEventManager.CommonEventSubscriber;
  private buffer: WatchedEvent[] = [];
  private started: boolean = false;
  private events: string[] = DEFAULT_EVENTS;
  /** 缓冲区上限，防止长跑内存膨胀。 */
  private readonly maxBuffer: number = 500;

  /** 开始常驻监听。重复调用安全（幂等）。 */
  async start(events?: string[]): Promise<void> {
    if (this.started) {
      return;
    }
    if (events !== undefined && events.length > 0) {
      this.events = events;
    }
    const info: commonEventManager.CommonEventSubscribeInfo = { events: this.events };
    this.subscriber = await commonEventManager.createSubscriber(info);
    const cb = (data: commonEventManager.CommonEventData): void => {
      this.push(data.event, data.code !== undefined ? data.code : 0);
    };
    await commonEventManager.subscribeToEvent(this.subscriber, cb);
    this.started = true;
    hilog.info(DOMAIN, TAG, 'watcher started, %{public}d events', this.events.length);
  }

  /** 停止监听并释放订阅。 */
  unsubscribe(): void {
    if (this.subscriber !== undefined) {
      try {
        commonEventManager.unsubscribe(this.subscriber);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'unsubscribe failed: %{public}s', JSON.stringify(err));
      }
    }
    this.subscriber = undefined;
    this.started = false;
  }

  /** 当前状态。 */
  status(): string {
    return JSON.stringify({
      started: this.started,
      subscribedEvents: this.events.length,
      buffered: this.buffer.length
    });
  }

  /** 读取（不清空）累积事件；sinceMs 只返回该时间戳之后的。 */
  read(sinceMs: number): WatchedEvent[] {
    if (sinceMs <= 0) {
      return this.buffer.slice();
    }
    return this.buffer.filter((e: WatchedEvent) => e.at >= sinceMs);
  }

  /** 清空缓冲（返回清空条数）。 */
  clear(): number {
    const n = this.buffer.length;
    this.buffer = [];
    return n;
  }

  private push(event: string, code: number): void {
    this.buffer.push({ at: Date.now(), event: event, code: code });
    if (this.buffer.length > this.maxBuffer) {
      this.buffer.shift();
    }
  }
}
