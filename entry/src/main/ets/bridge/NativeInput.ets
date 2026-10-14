/**
 * NativeInput —— libdshnative.so（NDK-only 能力）的 ArkTS 包装
 *
 * 与 ArkTS 侧既有能力的关系：
 *  - inputEventClient 注入（试用 ACL，10-16 到期）→ 本类是**免 ACL 的长期替代**（弹窗授权一次即可）
 *  - ui_mouse_move 等 hypium 注入（须 hdc/shell）→ 本类是**进程内**路径
 *
 * 结果码约定（Input_Result）：0=成功；201=权限拒绝；401=参数错；3900005=授权中；
 * 3900006=操作频繁；3900007=已授权；3900008=已授权他人；3900009=应用未聚焦。
 */
import dshnativeRaw from 'libdshnative.so';

export interface PointerLocation {
  code: number;      // Input_Result，0=成功
  displayId: number;
  x: number;
  y: number;
}

export interface PointerStyleResult {
  code: number;
  style: number;
}

export interface GetPointerStyleResult {
  ok: boolean;
  code: number;
  style: number;
}

/** v3：主窗信息（OH_WindowManager_GetAllMainWindowInfo @21） */
export interface NativeMainWindow {
  displayId: number;
  windowId: number;
  showing: boolean;   // true=前台
  label: string;      // 任务名
}

export interface ChildProcessProbe {
  ret: number;            // 0=机制可用；801=不支持；16010004=多进程被禁；16010005=已在子进程
  callbackCode: number;   // 异步回调带回的子进程启动结果（-999=尚未回调）
}

export interface HidProbeResult {
  deviceId: number;
  init: number;        // 0=成功
  open: number;        // 0=成功；201=缺 ACCESS_DDK_HID（system_basic，需 ACL）
  read: number;
  bytesRead: number;
  vendor?: number;
  product?: number;
  busType?: number;
  hex?: string;        // 原始 HID 报文字节（前 64 字节）
}

export interface RenderCardResult {
  code: number;        // 0=成功
  width: number;
  height: number;
  titleLen: number;
  subtitleLen: number;
}

export interface MainWindowsResult {
  code: number;       // 0=成功；需 CUSTOM_SCREEN_CAPTURE
  count: number;
  windows: NativeMainWindow[];
}

export interface NativeScreenshot {
  code: number;      // 0=成功；负数/ErrCode=失败
  width: number;
  height: number;
  stride: number;    // 每行字节数（=width*4 或更大）
  size: number;      // data 字节数
  data?: ArrayBuffer; // RGBA8888 原始像素
}

export interface NativeMouseEvent {
  action: number;   // 1=MOVE 2=BUTTON_DOWN 3=BUTTON_UP
  x: number;
  y: number;
  button: number;
  windowId: number;
}

/** 触摸事件（触摸屏/笔——本机有触摸屏；触控板不走这里）。 */
export interface NativeTouchEvent {
  action: number;      // InputEvent 动作码（0=DOWN 1=UP 2=MOVE 3=CANCEL…）
  fingerId: number;    // 手指 id：多指时用于区分不同触点
  toolType: number;    // 0=FINGER 1=PEN 2=RUBBER 3=BRUSH 4=PENCIL 5=AIRBRUSH 6=MOUSE 7=LENS
  displayId: number;
  windowId: number;
  pressure: number;
  displayX: number;
  displayY: number;
  globalX: number;
  globalY: number;
}

/** 轴事件——**触控板双指的真正通路**（全 SDK 唯一能读 sourceType 的事件）。 */
export interface NativeAxisEvent {
  action: number;      // 0=CANCEL 1=BEGIN 2=UPDATE 3=END
  eventType: number;   // 1=PINCH（捏合） 2=SCROLL（滚动）
  sourceType: number;  // 1=MOUSE 2=TOUCHSCREEN 3=TOUCHPAD
  pinchValue: number;
  scrollValue: number;
  displayId: number;
  windowId: number;
  globalX: number;
  globalY: number;
  displayX: number;
  displayY: number;
}

/** libdshnative.so 的方法签名（与 cpp/napi_input.cpp + napi_extras.cpp 注册表一一对应） */
interface DshNativeModule {
  getPointerLocation(): PointerLocation;
  requestInjection(): number;
  queryInjectionStatus(): number;
  injectKey(keyCode: number, action: number): number;
  injectMouse(action: number, x: number, y: number, button?: number, axisType?: number, axisValue?: number): number;
  injectTouch(action: number, x: number, y: number, fingerId?: number): number;
  getFunctionKeyState(keyCode: number): number;
  queryMaxTouchPoints(): number;
  lockCursor(windowId: number, followMovement?: number): number;
  unlockCursor(windowId: number): number;
  // v2（napi_extras.cpp）
  getIntervalSinceLastInput(): number;   // ms；负值=-错误码（INTERCEPT_INPUT_EVENT 未授时）
  setPointerStyle(windowId: number, style: number): number;
  getPointerStyle(windowId: number): PointerStyleResult;
  setPointerVisible(visible: number): number;
  startMouseMonitor(callback: (e: NativeMouseEvent) => void): number;
  stopMouseMonitor(): number;
  /** 触摸/触控板多指监视（INPUT_MONITORING；无「必须录屏」前置条件，触控板手势走这条） */
  startTouchMonitor(callback: (e: NativeTouchEvent) => void): number;
  stopTouchMonitor(): number;
  /** 轴事件监视（INPUT_MONITORING）：触控板双指的真正通路（sourceType=3=TOUCHPAD） */
  startAxisMonitor(callback: (e: NativeAxisEvent) => void): number;
  stopAxisMonitor(): number;
  traceBegin(name: string): number;
  traceEnd(): number;
  captureScreenshot(width: number, height: number): Promise<NativeScreenshot>;
  // v3（napi_extras_v3.cpp）：窗口信息与按窗/整屏截图
  getAllMainWindows(): MainWindowsResult;
  captureDisplay(displayId: number): Promise<NativeScreenshot>;
  captureWindow(windowId: number, width: number, height: number): Promise<NativeScreenshot>;
  probeNativeChildProcess(): ChildProcessProbe;
  renderCardToFd(fd: number, width: number, height: number, title: string, subtitle: string, accentArgb: number): RenderCardResult;
  hidProbe(deviceId: number, interfaceIndex: number): HidProbeResult;
}

// cpp/types/libdshnative 的类型映射在本构建链上未被解析（退化成 any），
// 这里用本地接口显式定型，绕过 arkts-no-any-unknown。
const dshnative: DshNativeModule = dshnativeRaw as DshNativeModule;

export interface NativeResult {
  ok: boolean;
  code: number;
}

export interface NativePointerResult extends NativeResult {
  displayId: number;
  x: number;
  y: number;
}

/** 注入授权状态 */
export enum InjectAuthStatus {
  UNAUTHORIZED = 0,
  AUTHORIZING = 1,
  AUTHORIZED = 2,
  NO_CALLBACK_YET = -1
}

export class NativeInput {
  /** 免权限读光标绝对坐标 */
  static getPointerLocation(): NativePointerResult {
    const r: PointerLocation = dshnative.getPointerLocation();
    return { ok: r.code === 0, code: r.code, displayId: r.displayId, x: r.x, y: r.y };
  }

  /** 触发注入授权弹窗（异步回调落地，用 queryInjectionStatus 轮询） */
  static requestInjection(): NativeResult {
    const code = dshnative.requestInjection();
    return { ok: code === 0 || code === 3900005 || code === 3900007, code };
  }

  /** 查询注入授权状态：0/1/2（-1=尚无回调） */
  static queryInjectionStatus(): NativeResult {
    const code = dshnative.queryInjectionStatus();
    return { ok: code === InjectAuthStatus.AUTHORIZED, code };
  }

  /** 键注入：keyCode 鸿蒙键码；action 1=按下 2=抬起。组合键由调用方按序 down/down/up/up */
  static injectKey(keyCode: number, action: number): NativeResult {
    const code = dshnative.injectKey(keyCode, action);
    return { ok: code === 0, code };
  }

  /** 鼠标移动（全局坐标） */
  static injectMouseMove(x: number, y: number): NativeResult {
    const code = dshnative.injectMouse(1, x, y);
    return { ok: code === 0, code };
  }

  /** 鼠标按键：button 0=左 1=中 2=右；down=true 按下 / false 抬起 */
  static injectMouseButton(x: number, y: number, button: number, down: boolean): NativeResult {
    const code = dshnative.injectMouse(down ? 2 : 3, x, y, button);
    return { ok: code === 0, code };
  }

  /** 鼠标滚轮：axisType 0=垂直 1=水平；axisValue 正=下/右 */
  static injectMouseAxis(x: number, y: number, axisType: number, axisValue: number): NativeResult {
    const code = dshnative.injectMouse(5, x, y, -1, axisType, axisValue);
    return { ok: code === 0, code };
  }

  /** 触摸注入：action 1=DOWN 2=MOVE 3=UP 0=CANCEL */
  static injectTouch(action: number, x: number, y: number, fingerId: number = 0): NativeResult {
    const code = dshnative.injectTouch(action, x, y, fingerId);
    return { ok: code === 0, code };
  }

  /** 修饰键状态（如 CapsLock/Fn）：0=关 1=开 */
  static getFunctionKeyState(keyCode: number): NativeResult {
    const code = dshnative.getFunctionKeyState(keyCode);
    return { ok: code >= 0, code };
  }

  /** 最大触点数 */
  static queryMaxTouchPoints(): NativeResult {
    const code = dshnative.queryMaxTouchPoints();
    return { ok: code >= 0, code };
  }

  /** 锁定光标到指定窗口（防止拖拽/点击期间光标移出） */
  static lockCursor(windowId: number, followMovement: boolean = true): NativeResult {
    const code = dshnative.lockCursor(windowId, followMovement ? 1 : 0);
    return { ok: code === 0, code };
  }

  /** 释放光标锁定 */
  static unlockCursor(windowId: number): NativeResult {
    const code = dshnative.unlockCursor(windowId);
    return { ok: code === 0, code };
  }

  // ================= v2（napi_extras.cpp） =================

  /** 距上次系统输入的间隔(ms)。负值=错误（INTERCEPT_INPUT_EVENT 未授，10-16 后预期失败） */
  static getIntervalSinceLastInput(): number {
    return dshnative.getIntervalSinceLastInput();
  }

  /** 设置指定窗口光标样式（style 见 oh_pointer_style.h，如 41=CURSOR_CIRCLE 49=LASER_CURSOR） */
  static setPointerStyle(windowId: number, style: number): NativeResult {
    const code = dshnative.setPointerStyle(windowId, style);
    return { ok: code === 0, code };
  }

  /** 读指定窗口光标样式 */
  static getPointerStyle(windowId: number): GetPointerStyleResult {
    const r: PointerStyleResult = dshnative.getPointerStyle(windowId);
    return { ok: r.code === 0, code: r.code, style: r.style };
  }

  /** 自动化执行期间隐藏/恢复光标（"机器在操作"可视化） */
  static setPointerVisible(visible: boolean): NativeResult {
    const code = dshnative.setPointerVisible(visible ? 1 : 0);
    return { ok: code === 0, code };
  }

  /** 启动全局鼠标事件监听（INPUT_MONITORING，试用 ACL 期内可用） */
  static startMouseMonitor(callback: (e: NativeMouseEvent) => void): NativeResult {
    const code = dshnative.startMouseMonitor(callback);
    return { ok: code === 0, code };
  }

  /** 停止鼠标事件监听 */
  static stopMouseMonitor(): NativeResult {
    const code = dshnative.stopMouseMonitor();
    return { ok: code === 0, code };
  }

  /**
   * 启动触摸/触控板多指事件监听（INPUT_MONITORING）。
   * 与鼠标监视器的区别：无「必须在录屏场景」的前置条件，触控板多指走这条。
   */
  static startTouchMonitor(callback: (e: NativeTouchEvent) => void): NativeResult {
    const code = dshnative.startTouchMonitor(callback);
    return { ok: code === 0, code };
  }

  /** 停止触摸事件监听 */
  static stopTouchMonitor(): NativeResult {
    const code = dshnative.stopTouchMonitor();
    return { ok: code === 0, code };
  }

  /**
   * 启动轴事件监听（INPUT_MONITORING）——**触控板双指的真正通路**。
   * 事件里 `sourceType` 区分来源：1=鼠标 2=触摸屏 3=触控板；
   * `eventType`：1=PINCH（捏合）2=SCROLL（滚动）；`action`：1=BEGIN 2=UPDATE 3=END。
   */
  static startAxisMonitor(callback: (e: NativeAxisEvent) => void): NativeResult {
    const code = dshnative.startAxisMonitor(callback);
    return { ok: code === 0, code };
  }

  /** 停止轴事件监听 */
  static stopAxisMonitor(): NativeResult {
    const code = dshnative.stopAxisMonitor();
    return { ok: code === 0, code };
  }

  /** HiTrace 打点开始（出现在系统 trace，自动化延迟诊断） */
  static traceBegin(name: string): NativeResult {
    const code = dshnative.traceBegin(name);
    return { ok: code === 0, code };
  }

  /** HiTrace 打点结束 */
  static traceEnd(): NativeResult {
    const code = dshnative.traceEnd();
    return { ok: code === 0, code };
  }

  /** 进程内单帧截屏（OH_AVScreenCapture，RGBA8888 buffer；替代 ArkTS 截图三跳链） */
  static async captureScreenshot(width: number, height: number): Promise<NativeScreenshot> {
    return dshnative.captureScreenshot(width, height);
  }

  // ================= v3（napi_extras_v3.cpp）=================

  /** 所有主窗信息：{displayId, windowId, showing(前后台), label(任务名)}，需 CUSTOM_SCREEN_CAPTURE */
  static getAllMainWindows(): MainWindowsResult {
    return dshnative.getAllMainWindows();
  }

  /** 轻量整屏截图（OH_NativeDisplayManager_CaptureScreenPixelmap，比 AVScreenCapture pipeline 轻） */
  static async captureDisplay(displayId: number = 0): Promise<NativeScreenshot> {
    return dshnative.captureDisplay(displayId);
  }

  /** 按窗截图（OH_WindowManager_GetMainWindowSnapshot，需 CUSTOM_SCREEN_CAPTURE；width/height 传窗口 rect 尺寸） */
  static async captureWindow(windowId: number, width: number, height: number): Promise<NativeScreenshot> {
    return dshnative.captureWindow(windowId, width, height);
  }

  /** NativeChildProcess 可用性探针（评估用；用不存在的 lib 名只探机制门槛） */
  static probeNativeChildProcess(): ChildProcessProbe {
    return dshnative.probeNativeChildProcess();
  }

  /** v5：HID DDK 探针（打开外接 HID + 非阻塞读一次原始报文；需 ACCESS_DDK_HID） */
  static hidProbe(deviceId: number, interfaceIndex: number = 0): HidProbeResult {
    return dshnative.hidProbe(deviceId, interfaceIndex);
  }

  /**
   * v4：NDK 离屏渲染卡片并直接把 PNG 写进 fd（native_drawing + image_packer）。
   * 零组件树、零窗口依赖——替代 ArkTS 的 createFromBuilder（后者在非组件宿主上下文必炸）。
   */
  static renderCardToFd(fd: number, width: number, height: number,
                        title: string, subtitle: string, accentArgb: number = 0): RenderCardResult {
    return dshnative.renderCardToFd(fd, width, height, title, subtitle, accentArgb);
  }
}
