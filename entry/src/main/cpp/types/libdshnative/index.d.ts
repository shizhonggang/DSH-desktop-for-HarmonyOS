/**
 * libdshnative.so 的类型声明（napi 模块名 dshnative）
 * 实现见 entry/src/main/cpp/napi_input.cpp
 */

export interface PointerLocation {
  code: number;      // Input_Result，0=成功
  displayId: number;
  x: number;
  y: number;
}

/** 免权限读光标绝对坐标 */
export const getPointerLocation: () => PointerLocation;

/** 触发输入注入授权弹窗；返回 Input_Result（0=已受理，3900005=授权中…） */
export const requestInjection: () => number;

/** 查询注入授权状态：0=未授权 1=授权中 2=已授权（-1=尚无回调结果） */
export const queryInjectionStatus: () => number;

/** 键注入：action 1=DOWN 2=UP；keyCode 用鸿蒙键码（如 2038=V） */
export const injectKey: (keyCode: number, action: number) => number;

/** 鼠标注入（全局）：action 1=MOVE 2=DOWN 3=UP 4/5/6=AXIS_*；button -1=无 0=左 1=中 2=右 */
export const injectMouse: (action: number, x: number, y: number,
  button?: number, axisType?: number, axisValue?: number) => number;

/** 触摸注入：action 0=CANCEL 1=DOWN 2=MOVE 3=UP */
export const injectTouch: (action: number, x: number, y: number, fingerId?: number) => number;

/** 修饰键状态（如 Fn/CapsLock）：0=关 1=开；负数=错误码 */
export const getFunctionKeyState: (keyCode: number) => number;

/** 最大触点数；负数=错误码 */
export const queryMaxTouchPoints: () => number;

/** 锁定光标到窗口（权限 LOCK_WINDOW_CURSOR 已声明，normal 级） */
export const lockCursor: (windowId: number, followMovement?: number) => number;

/** 释放光标锁定 */
export const unlockCursor: (windowId: number) => number;
