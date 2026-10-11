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
  traceBegin(name: string): number;
  traceEnd(): number;
  captureScreenshot(width: number, height: number): Promise<NativeScreenshot>;
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
}
