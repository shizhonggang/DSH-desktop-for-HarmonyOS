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
 * Accessibility side of the DSH bridge.
 *
 * The UI side (`bridge/BridgeAgent.ets`) can launch apps but cannot touch other
 * apps' interfaces — `uitest` / `snapshot_display` are SELinux-fenced for this
 * app domain. Real "read the screen / click a button" needs an accessibility
 * service, which is what this file is: it runs inside
 * `DshAccessibilityAbility` and only works after the user enables the extension
 * in 设置 → 辅助功能.
 *
 * It polls the same node server as the UI side, but on a separate channel
 * (`/poll?channel=a11y`) so the two pollers never steal each other's commands.
 *
 * Actions: a11yPing / a11yWindows / a11yFind / a11yFocus / a11yClick /
 *          a11yTap / a11ySwipe / a11yLastEvent
 */

import { AccessibilityElement, AccessibilityExtensionContext, GesturePath, GesturePoint, Rect } from '@kit.AccessibilityKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'DshA11y';

const HTTP_OK = 200;
const POLL_GAP_MS = 200;
const POLL_RETRY_MS = 2000;
const POLL_READ_TIMEOUT_MS = 30000;
const POST_READ_TIMEOUT_MS = 5000;
const CHANNEL = 'a11y';

interface BridgeCommand {
  id: string;
  action: string;
  args: Record<string, Object>;
}

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

/** Flattened view of one node, safe to JSON-serialise across the bridge. */
export interface ElementView {
  bundleName: string;
  componentType: string;
  text: string;
  description: string;
  hintText: string;
  isVisible: boolean;
  clickable: boolean;
  checked: boolean;
  actions: string[];
  windowId: number;
  left: number;
  top: number;
  width: number;
  height: number;
}

export class AccessibilityBridgeAgent {
  private context: AccessibilityExtensionContext;
  private baseUrl: string;
  private timer: number = -1;
  private busy: boolean = false;
  private stopped: boolean = true;
  private lastEvent: string = '';

  constructor(context: AccessibilityExtensionContext, port: number) {
    this.context = context;
    this.baseUrl = 'http://127.0.0.1:' + port.toString();
  }

  start(): void {
    if (!this.stopped) {
      return;
    }
    this.stopped = false;
    hilog.info(DOMAIN, TAG, 'accessibility bridge started against %{public}s', this.baseUrl);
    this.schedule(0);
  }

  stop(): void {
    this.stopped = true;
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'accessibility bridge stopped');
  }

  /** Records the newest accessibility event so callers can see what is happening. */
  noteEvent(description: string): void {
    this.lastEvent = description;
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
      this.schedule(POLL_RETRY_MS);
    });
  }

  private async pollOnce(): Promise<void> {
    const reply = await this.request('/poll?channel=' + CHANNEL, http.RequestMethod.GET, '', POLL_READ_TIMEOUT_MS);
    if (reply.code === 0) {
      throw new Error('bridge server unreachable');
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
    const replyBody = await this.execute(command);
    try {
      await this.request('/result', http.RequestMethod.POST, JSON.stringify(replyBody), POST_READ_TIMEOUT_MS);
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
    if (action === 'a11yPing') {
      return Promise.resolve('{"pong":true,"channel":"a11y"}');
    }
    if (action === 'a11yWindows') {
      return this.windows();
    }
    if (action === 'a11yFocus') {
      return this.focus();
    }
    if (action === 'a11yFind') {
      return this.find(args);
    }
    if (action === 'a11yClick') {
      return this.click(args);
    }
    if (action === 'a11yTap') {
      return this.tap(args);
    }
    if (action === 'a11ySwipe') {
      return this.swipe(args);
    }
    if (action === 'a11yLastEvent') {
      return Promise.resolve('{"lastEvent":' + JSON.stringify(this.lastEvent) + '}');
    }
    return Promise.reject(new Error('unsupported a11y action: ' + action));
  }

  /** Screen-level listing: one entry per window. */
  private async windows(): Promise<string> {
    const all: AccessibilityElement[] = await this.context.getWindows();
    const views: ElementView[] = [];
    for (let i = 0; i < all.length; i++) {
      views.push(await this.describe(all[i]));
    }
    return JSON.stringify({ count: views.length, windows: views });
  }

  /** The element that currently has focus — the closest thing to "where am I". */
  private async focus(): Promise<string> {
    try {
      const element: AccessibilityElement = await this.context.getFocusElement();
      return JSON.stringify({ focus: await this.describe(element) });
    } catch (err) {
      throw new Error('getFocusElement failed: ' + this.text(err));
    }
  }

  /**
   * Free-text search across every window. `match` is matched with
   * findElement('content', ...) which the system does on the element's subtree.
   */
  private async find(args: Record<string, Object>): Promise<string> {
    const match = this.stringArg(args, 'match');
    if (match.length === 0) {
      throw new Error('a11yFind: "match" is required');
    }
    const limit = this.numberArg(args, 'limit', 20);
    const windowsList: AccessibilityElement[] = await this.context.getWindows();
    const hits: ElementView[] = [];
    for (let i = 0; i < windowsList.length && hits.length < limit; i++) {
      try {
        const found: AccessibilityElement[] = await windowsList[i].findElement('content', match);
        for (let j = 0; j < found.length && hits.length < limit; j++) {
          hits.push(await this.describe(found[j]));
        }
      } catch (err) {
        // A window may not support content search; keep going.
      }
    }
    return JSON.stringify({ match: match, count: hits.length, elements: hits });
  }

  /** Finds by text and clicks it (performAction('click')). */
  private async click(args: Record<string, Object>): Promise<string> {
    const match = this.stringArg(args, 'match');
    if (match.length === 0) {
      throw new Error('a11yClick: "match" is required');
    }
    const index = this.numberArg(args, 'index', 0);
    const windowsList: AccessibilityElement[] = await this.context.getWindows();
    const found: AccessibilityElement[] = [];
    for (let i = 0; i < windowsList.length; i++) {
      try {
        const hits: AccessibilityElement[] = await windowsList[i].findElement('content', match);
        for (let j = 0; j < hits.length; j++) {
          found.push(hits[j]);
        }
      } catch (err) {
        // ignore windows that do not support the search
      }
    }
    if (found.length === 0) {
      throw new Error(`no element matched "${match}" (try a11yFind first)`);
    }
    if (index >= found.length) {
      throw new Error(`index ${index} out of range, only ${found.length} match(es)`);
    }
    const target = found[index];
    const view = await this.describe(target);
    const actions = await this.actionNames(target);
    if (actions.indexOf('click') < 0) {
      throw new Error(`element "${match}" is not clickable; supported actions: ${actions.join(', ')}`);
    }
    try {
      await target.performAction('click');
    } catch (err) {
      throw new Error('performAction(click) failed: ' + this.text(err));
    }
    return JSON.stringify({ clicked: true, match: match, index: index, matched: found.length, element: view });
  }

  /** Single tap at absolute coordinates (for elements that expose no text). */
  private async tap(args: Record<string, Object>): Promise<string> {
    const x = this.numberArg(args, 'x', -1);
    const y = this.numberArg(args, 'y', -1);
    if (x < 0 || y < 0) {
      throw new Error('a11yTap: "x" and "y" are required');
    }
    const path = new GesturePath(100);
    path.points = [new GesturePoint(x, y)];
    this.context.injectGestureSync(path);
    return '{"tapped":true,"x":' + x.toString() + ',"y":' + y.toString() + '}';
  }

  /** Swipe / drag / scroll between two points. */
  private async swipe(args: Record<string, Object>): Promise<string> {
    const x1 = this.numberArg(args, 'x1', -1);
    const y1 = this.numberArg(args, 'y1', -1);
    const x2 = this.numberArg(args, 'x2', -1);
    const y2 = this.numberArg(args, 'y2', -1);
    if (x1 < 0 || y1 < 0 || x2 < 0 || y2 < 0) {
      throw new Error('a11ySwipe: "x1","y1","x2","y2" are required');
    }
    const duration = this.numberArg(args, 'duration', 300);
    const path = new GesturePath(duration);
    path.points = [new GesturePoint(x1, y1), new GesturePoint(x2, y2)];
    this.context.injectGestureSync(path);
    return '{"swiped":true}';
  }

  private async actionNames(element: AccessibilityElement): Promise<string[]> {
    try {
      return await element.actionNames();
    } catch (err) {
      return [];
    }
  }

  /**
   * Reads the attributes we care about into a flat, serialisable view.
   * Each attribute is read individually because the generic type parameter of
   * `attributeValue` is inferred per string literal.
   */
  private async describe(element: AccessibilityElement): Promise<ElementView> {
    const view: ElementView = {
      bundleName: await this.str(element, 'bundleName'),
      componentType: await this.str(element, 'componentType'),
      text: await this.str(element, 'text'),
      description: await this.str(element, 'description'),
      hintText: await this.str(element, 'hintText'),
      isVisible: await this.bool(element, 'isVisible'),
      clickable: await this.bool(element, 'clickable'),
      checked: await this.bool(element, 'checked'),
      actions: await this.actionNames(element),
      windowId: await this.num(element, 'windowId'),
      left: 0,
      top: 0,
      width: 0,
      height: 0
    };
    const rect = await this.rect(element);
    view.left = rect.left;
    view.top = rect.top;
    view.width = rect.width;
    view.height = rect.height;
    return view;
  }

  private async str(element: AccessibilityElement, key: string): Promise<string> {
    try {
      if (key === 'bundleName') {
        return await element.attributeValue('bundleName');
      }
      if (key === 'componentType') {
        return await element.attributeValue('componentType');
      }
      if (key === 'text') {
        return await element.attributeValue('text');
      }
      if (key === 'description') {
        return await element.attributeValue('description');
      }
      if (key === 'hintText') {
        return await element.attributeValue('hintText');
      }
    } catch (err) {
      // attribute not supported on this node
    }
    return '';
  }

  private async bool(element: AccessibilityElement, key: string): Promise<boolean> {
    try {
      if (key === 'isVisible') {
        return await element.attributeValue('isVisible');
      }
      if (key === 'clickable') {
        return await element.attributeValue('clickable');
      }
      if (key === 'checked') {
        return await element.attributeValue('checked');
      }
    } catch (err) {
      // attribute not supported on this node
    }
    return false;
  }

  private async num(element: AccessibilityElement, key: string): Promise<number> {
    try {
      if (key === 'windowId') {
        return await element.attributeValue('windowId');
      }
    } catch (err) {
      // attribute not supported on this node
    }
    return 0;
  }

  private async rect(element: AccessibilityElement): Promise<Rect4> {
    const empty: Rect4 = { left: 0, top: 0, width: 0, height: 0 };
    try {
      // Rect is a plain interface here ({left, top, width, height}); ArkTS
      // rejects casting it to Record<string, number>, so read the fields.
      const raw = await element.attributeValue('rect');
      if (raw === undefined || raw === null) {
        return empty;
      }
      const box = raw as Rect;
      return { left: box.left, top: box.top, width: box.width, height: box.height };
    } catch (err) {
      return empty;
    }
  }

  private request(path: string, method: http.RequestMethod, body: string, readTimeoutMs: number): Promise<HttpReply> {
    return new Promise<HttpReply>((resolve) => {
      const request = http.createHttp();
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
        resolve({ code: 0, body: '' });
        request.destroy();
      });
    });
  }

  private stringArg(args: Record<string, Object>, key: string): string {
    const value = args[key];
    return typeof value === 'string' ? value as string : '';
  }

  private numberArg(args: Record<string, Object>, key: string, fallback: number): number {
    const value = args[key];
    return typeof value === 'number' ? value as number : fallback;
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

interface Rect4 {
  left: number;
  top: number;
  width: number;
  height: number;
}
