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
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { notificationManager } from '@kit.NotificationKit';
import { formProvider, formInfo } from '@kit.FormKit';
import pasteboard from '@ohos.pasteboard';
import window from '@ohos.window';
import display from '@ohos.display';
import image from '@ohos.multimedia.image';
import fileIo from '@ohos.file.fs';
import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl';
import { Driver, ON, Component } from '@ohos.UiTest';
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
    if (action === 'setClipboard') {
      return this.setClipboard(args);
    }
    if (action === 'getClipboard') {
      return this.getClipboard();
    }
    if (action === 'uiTestProbe') {
      return this.uiTestProbe();
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
   * Probe whether the in-process UiTest API (@ohos.UiTest) is usable.
   * If it works, DSH can drive the whole machine without hdc.
   */
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
      if (size > maxBytes) {
        throw new Error('fetchFile: file is ' + size.toString() + ' bytes, over the ' +
          maxBytes.toString() + ' byte cap; raise "maxBytes" if this is intended');
      }
      const file: fileIo.File = fileIo.openSync(p, fileIo.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(size);
      const read = fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      const bytes = new Uint8Array(buf.slice(0, read));
      const b64 = this.base64(bytes);
      return '{"ok":true,"path":"' + this.esc(p) + '","size":' + read.toString() +
        ',"base64":"' + b64 + '"}';
    } catch (err) {
      throw new Error('fetchFile: ' + this.text(err));
    }
  }

  /** Minimal standard-alphabet base64 encoder (ArkTS has no Buffer). */
  private base64(bytes: Uint8Array): string {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let out = '';
    for (let i = 0; i < bytes.length; i += 3) {
      const b0 = bytes[i];
      const hasB1 = i + 1 < bytes.length;
      const hasB2 = i + 2 < bytes.length;
      const b1 = hasB1 ? bytes[i + 1] : 0;
      const b2 = hasB2 ? bytes[i + 2] : 0;
      out += alphabet.charAt(b0 >> 2);
      out += alphabet.charAt(((b0 & 0x03) << 4) | (b1 >> 4));
      out += hasB1 ? alphabet.charAt(((b1 & 0x0f) << 2) | (b2 >> 6)) : '=';
      out += hasB2 ? alphabet.charAt(b2 & 0x3f) : '=';
    }
    return out;
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
