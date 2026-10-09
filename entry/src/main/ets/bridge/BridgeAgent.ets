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

import { common, Want, wantAgent, WantAgent } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { notificationManager } from '@kit.NotificationKit';
import { formProvider, formInfo } from '@kit.FormKit';
import DshFormAbility from '../formability/DshFormAbility';

const DOMAIN = 0x0000;
const TAG = 'DshBridge';

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
/** EntryAbility owns id 1001 (background tray notice); stay out of its way. */
const NOTIFY_ID_BASE = 2000;
const NOTIFY_ID_SPAN = 100000;

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
    this.schedule(0);
  }

  /** Stops the poll loop. */
  stop(): void {
    this.stopped = true;
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
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
    if (action === 'dismissNotification') {
      return this.dismissNotification(args);
    }
    if (action === 'updateCard') {
      return this.updateCard(args);
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
        wantAgent: agent
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
        wantAgent: agent
      };
      await notificationManager.publish(basicRequest);
    }
    hilog.info(DOMAIN, TAG, 'notification published id=%{public}d', id);
    return '{"published":true,"id":' + id.toString() + '}';
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
    try {
      const formIds: formInfo.RunningFormInfo[] = await formProvider.getPublishedRunningFormInfos();
      const mine = formIds.filter((info: formInfo.RunningFormInfo) =>
        info.bundleName === SHELL_BUNDLE_NAME
      );
      for (const info of mine) {
        DshFormAbility.updateCardData(this.abilityContext, info.formId, data);
      }
      return '{"updated":true,"cards":' + mine.length.toString() + '}';
    } catch (err) {
      throw new Error('updateCard: ' + this.text(err));
    }
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

  private notificationId(args: Record<string, Object>): number {
    const provided = this.numberArg(args, 'id');
    if (provided > 0) {
      return provided;
    }
    this.notificationSeq += 1;
    return NOTIFY_ID_BASE + (this.notificationSeq % NOTIFY_ID_SPAN);
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

  private text(value: Object): string {
    if (value instanceof Error) {
      return (value as Error).message;
    }
    if (typeof value === 'string') {
      return value as string;
    }
    return JSON.stringify(value);
  }
}
