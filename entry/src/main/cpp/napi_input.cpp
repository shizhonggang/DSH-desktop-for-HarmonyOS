/**
 * dshnative —— NDK-only 自动化能力的 napi 封装（v1）
 *
 * 背景（CC knowledge/14 §八.B）：以下能力 ArkTS 层没有模块，只有 NDK 头文件：
 *  - OH_Input_GetPointerLocation      免权限读光标绝对坐标（@20）
 *  - OH_Input_RequestInjection        免 ACL 输入注入授权（弹窗授权模型，@20）
 *  - OH_Input_QueryAuthorizedStatus   注入授权状态查询（@20）
 *  - OH_Input_Inject{Key,Mouse,Touch}Event(Global)  原生注入（@12，建议先 RequestInjection）
 *  - OH_Input_GetFunctionKeyState     修饰键状态（@15，无权限）
 *  - OH_Input_QueryMaxTouchPoints     最大触点数（@20，无权限）
 *  - OH_WindowManager_LockCursor/UnlockCursor  光标锁定（@22，LOCK_WINDOW_CURSOR=normal 已声明）
 *
 * 约定：除 getPointerLocation 返回对象外，所有函数返回 int32 结果码
 * （Input_Result：0=成功，201=权限拒绝，3900005=授权中，3900007=已授权…）。
 */
#include <napi/native_api.h>
#include <multimodalinput/oh_input_manager.h>
#include <window_manager/oh_window.h>
#include <hilog/log.h>
#include <time.h>

// 注入事件的动作时间：CLOCK_MONOTONIC（开机毫秒），与系统输入事件时钟一致
static int64_t NowMs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

#define LOG_DOMAIN 0xD511
#define LOG_TAG "dshnative"

// 最近一次 RequestInjection 回调带回的授权状态（0/1/2，-1=尚未回调）
static volatile int32_t g_injectCallbackStatus = -1;

static void OnInjectAuthorize(Input_InjectionStatus status) {
    g_injectCallbackStatus = static_cast<int32_t>(status);
    OH_LOG_INFO(LOG_APP, "injection authorize callback: %{public}d", status);
}

// ---------- 工具 ----------
static napi_value MakeInt(napi_env env, int32_t v) {
    napi_value out;
    napi_create_int32(env, v, &out);
    return out;
}

static bool GetInt32(napi_env env, napi_value v, int32_t *out) {
    return napi_get_value_int32(env, v, out) == napi_ok;
}

static bool GetDouble(napi_env env, napi_value v, double *out) {
    return napi_get_value_double(env, v, out) == napi_ok;
}

// ---------- 1. 光标绝对坐标（免权限） ----------
// getPointerLocation() → {code, displayId, x, y}
static napi_value GetPointerLocation(napi_env env, napi_callback_info info) {
    int32_t displayId = -1;
    double x = -1, y = -1;
    Input_Result ret = OH_Input_GetPointerLocation(&displayId, &x, &y);
    napi_value obj;
    napi_create_object(env, &obj);
    napi_set_named_property(env, obj, "code", MakeInt(env, static_cast<int32_t>(ret)));
    napi_set_named_property(env, obj, "displayId", MakeInt(env, displayId));
    napi_value vx, vy;
    napi_create_double(env, x, &vx);
    napi_create_double(env, y, &vy);
    napi_set_named_property(env, obj, "x", vx);
    napi_set_named_property(env, obj, "y", vy);
    return obj;
}

// ---------- 2. 注入授权 ----------
// requestInjection() → Input_Result（触发系统授权弹窗；结果经回调落地）
static napi_value RequestInjection(napi_env env, napi_callback_info info) {
    Input_Result ret = OH_Input_RequestInjection(OnInjectAuthorize);
    OH_LOG_INFO(LOG_APP, "RequestInjection ret=%{public}d", ret);
    return MakeInt(env, static_cast<int32_t>(ret));
}

// queryInjectionStatus() → 0 未授权 / 1 授权中 / 2 已授权（-1=查询失败）
static napi_value QueryInjectionStatus(napi_env env, napi_callback_info info) {
    Input_InjectionStatus status = UNAUTHORIZED;
    Input_Result ret = OH_Input_QueryAuthorizedStatus(&status);
    if (ret != INPUT_SUCCESS) {
        // 查询失败时回退到回调缓存值
        return MakeInt(env, g_injectCallbackStatus);
    }
    return MakeInt(env, static_cast<int32_t>(status));
}

// ---------- 3. 键注入 ----------
// injectKey(keyCode:int, action:int)  action: 1=KEY_ACTION_DOWN 2=KEY_ACTION_UP
static napi_value InjectKey(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t keyCode = 0, action = KEY_ACTION_DOWN;
    if (argc < 2 || !GetInt32(env, args[0], &keyCode) || !GetInt32(env, args[1], &action)) {
        return MakeInt(env, INPUT_PARAMETER_ERROR);
    }
    struct Input_KeyEvent *ev = OH_Input_CreateKeyEvent();
    if (ev == nullptr) {
        return MakeInt(env, INPUT_SERVICE_EXCEPTION);
    }
    OH_Input_SetKeyEventKeyCode(ev, keyCode);
    OH_Input_SetKeyEventAction(ev, action);
    OH_Input_SetKeyEventActionTime(ev, NowMs());
    int32_t ret = OH_Input_InjectKeyEvent(ev);
    OH_Input_DestroyKeyEvent(&ev);
    OH_LOG_INFO(LOG_APP, "InjectKey code=%{public}d action=%{public}d ret=%{public}d", keyCode, action, ret);
    return MakeInt(env, ret);
}

// ---------- 4. 鼠标注入（全局） ----------
// injectMouse(action:int, x:int, y:int, button:int=-1, axisType:int=-1, axisValue:number=0)
// action: 1=MOVE 2=BUTTON_DOWN 3=BUTTON_UP 4/5/6=AXIS_*
static napi_value InjectMouse(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t action = 0, x = 0, y = 0, button = MOUSE_BUTTON_NONE, axisType = -1;
    double axisValue = 0;
    if (argc < 3 || !GetInt32(env, args[0], &action) || !GetInt32(env, args[1], &x) || !GetInt32(env, args[2], &y)) {
        return MakeInt(env, INPUT_PARAMETER_ERROR);
    }
    if (argc > 3) { GetInt32(env, args[3], &button); }
    if (argc > 4) { GetInt32(env, args[4], &axisType); }
    if (argc > 5) { GetDouble(env, args[5], &axisValue); }
    struct Input_MouseEvent *ev = OH_Input_CreateMouseEvent();
    if (ev == nullptr) {
        return MakeInt(env, INPUT_SERVICE_EXCEPTION);
    }
    OH_Input_SetMouseEventAction(ev, action);
    OH_Input_SetMouseEventGlobalX(ev, x);
    OH_Input_SetMouseEventGlobalY(ev, y);
    OH_Input_SetMouseEventActionTime(ev, NowMs());
    if (button != MOUSE_BUTTON_NONE) {
        OH_Input_SetMouseEventButton(ev, button);
    }
    if (axisType >= 0) {
        OH_Input_SetMouseEventAxisType(ev, axisType);
        OH_Input_SetMouseEventAxisValue(ev, static_cast<float>(axisValue));
    }
    int32_t ret = OH_Input_InjectMouseEventGlobal(ev);
    OH_Input_DestroyMouseEvent(&ev);
    OH_LOG_INFO(LOG_APP, "InjectMouse action=%{public}d x=%{public}d y=%{public}d ret=%{public}d", action, x, y, ret);
    return MakeInt(env, ret);
}

// ---------- 5. 触摸注入 ----------
// injectTouch(action:int, x:int, y:int, fingerId:int=0)  action: 1=DOWN 2=MOVE 3=UP 0=CANCEL
static napi_value InjectTouch(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t action = 0, x = 0, y = 0, fingerId = 0;
    if (argc < 3 || !GetInt32(env, args[0], &action) || !GetInt32(env, args[1], &x) || !GetInt32(env, args[2], &y)) {
        return MakeInt(env, INPUT_PARAMETER_ERROR);
    }
    if (argc > 3) { GetInt32(env, args[3], &fingerId); }
    struct Input_TouchEvent *ev = OH_Input_CreateTouchEvent();
    if (ev == nullptr) {
        return MakeInt(env, INPUT_SERVICE_EXCEPTION);
    }
    OH_Input_SetTouchEventAction(ev, action);
    OH_Input_SetTouchEventDisplayX(ev, x);
    OH_Input_SetTouchEventDisplayY(ev, y);
    OH_Input_SetTouchEventFingerId(ev, fingerId);
    OH_Input_SetTouchEventDisplayId(ev, 0);
    OH_Input_SetTouchEventActionTime(ev, NowMs());
    int32_t ret = OH_Input_InjectTouchEvent(ev);
    OH_Input_DestroyTouchEvent(&ev);
    OH_LOG_INFO(LOG_APP, "InjectTouch action=%{public}d x=%{public}d y=%{public}d ret=%{public}d", action, x, y, ret);
    return MakeInt(env, ret);
}

// ---------- 6. 修饰键状态（免权限） ----------
// getFunctionKeyState(keyCode:int) → 0/1（-err 为失败）
static napi_value GetFunctionKeyState(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t keyCode = 0, state = 0;
    if (argc < 1 || !GetInt32(env, args[0], &keyCode)) {
        return MakeInt(env, INPUT_PARAMETER_ERROR);
    }
    Input_Result ret = OH_Input_GetFunctionKeyState(keyCode, &state);
    if (ret != INPUT_SUCCESS) {
        return MakeInt(env, -static_cast<int32_t>(ret));
    }
    return MakeInt(env, state);
}

// ---------- 7. 最大触点数（免权限） ----------
static napi_value QueryMaxTouchPoints(napi_env env, napi_callback_info info) {
    int32_t count = 0;
    Input_Result ret = OH_Input_QueryMaxTouchPoints(&count);
    if (ret != INPUT_SUCCESS) {
        return MakeInt(env, -static_cast<int32_t>(ret));
    }
    return MakeInt(env, count);
}

// ---------- 8/9. 光标锁定（LOCK_WINDOW_CURSOR=normal，module.json5 已声明） ----------
// lockCursor(windowId:int, followMovement:bool) / unlockCursor(windowId:int)
static napi_value LockCursor(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t windowId = -1, follow = 1;
    if (argc < 1 || !GetInt32(env, args[0], &windowId)) {
        return MakeInt(env, INPUT_PARAMETER_ERROR);
    }
    if (argc > 1) { GetInt32(env, args[1], &follow); }
    int32_t ret = OH_WindowManager_LockCursor(windowId, follow != 0);
    OH_LOG_INFO(LOG_APP, "LockCursor win=%{public}d ret=%{public}d", windowId, ret);
    return MakeInt(env, ret);
}

static napi_value UnlockCursor(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t windowId = -1;
    if (argc < 1 || !GetInt32(env, args[0], &windowId)) {
        return MakeInt(env, INPUT_PARAMETER_ERROR);
    }
    int32_t ret = OH_WindowManager_UnlockCursor(windowId);
    OH_LOG_INFO(LOG_APP, "UnlockCursor win=%{public}d ret=%{public}d", windowId, ret);
    return MakeInt(env, ret);
}

// ---------- 模块注册 ----------
// v2 增补能力（napi_extras.cpp，session-43e17adf）：在此合并注册到同一 exports
extern napi_value RegisterDshNativeExtras(napi_env env, napi_value exports);
// v3 窗口能力（napi_extras_v3.cpp，session-43e17adf）
extern napi_value RegisterDshNativeV3(napi_env env, napi_value exports);
// v4 离屏渲染（napi_extras_v4.cpp，session-43e17adf）
extern napi_value RegisterDshNativeV4(napi_env env, napi_value exports);
// v5 HID DDK 探针（napi_extras_v5.cpp，session-43e17adf）
extern napi_value RegisterDshNativeV5(napi_env env, napi_value exports);

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"getPointerLocation", nullptr, GetPointerLocation, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"requestInjection", nullptr, RequestInjection, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"queryInjectionStatus", nullptr, QueryInjectionStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"injectKey", nullptr, InjectKey, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"injectMouse", nullptr, InjectMouse, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"injectTouch", nullptr, InjectTouch, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getFunctionKeyState", nullptr, GetFunctionKeyState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"queryMaxTouchPoints", nullptr, QueryMaxTouchPoints, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"lockCursor", nullptr, LockCursor, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"unlockCursor", nullptr, UnlockCursor, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    RegisterDshNativeExtras(env, exports);
    RegisterDshNativeV3(env, exports);
    RegisterDshNativeV4(env, exports);
    RegisterDshNativeV5(env, exports);
    return exports;
}
EXTERN_C_END

static napi_module dshNativeModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "dshnative",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterDshNativeModule(void) {
    napi_module_register(&dshNativeModule);
}
