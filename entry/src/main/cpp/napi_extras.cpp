/**
 * dshnative —— NDK-only 自动化能力 napi 封装（v2 增补，本会话 session-43e17adf）
 *
 * v2 新增（与 v1 napi_input.cpp 同一 libdshnative.so）：
 *  - getIntervalSinceLastInput   距上次系统输入的间隔(ms)（INTERCEPT_INPUT_EVENT，试用 ACL 期内可用）
 *  - setPointerStyle/getPointerStyle/setPointerVisible  光标样式与可见性（@22，无权限标注）
 *  - startMouseMonitor/stopMouseMonitor  全局鼠标事件监听（INPUT_MONITORING，TSFN 回调 ArkTS）
 *  - traceBegin/traceEnd         HiTrace 链路打点（自动化延迟诊断）
 *  - captureScreenshot           OH_AVScreenCapture 单帧截屏（异步 Promise，进程内拿 RGBA buffer，
 *                                替代「ArkTS截图→沙箱文件→fetchFile base64」三跳链）
 */
#include <napi/native_api.h>
#include <multimodalinput/oh_input_manager.h>
#include <hitrace/trace.h>
#include <multimedia/player_framework/native_avscreen_capture.h>
#include <native_buffer/native_buffer.h>
#include <hilog/log.h>
#include <unistd.h>
#include <cstring>
#include <vector>
#include <thread>
#include <chrono>

#define LOG_DOMAIN 0xD512
#define LOG_TAG "dshnative-ex"

// ---------- 工具 ----------
static napi_value MakeInt(napi_env env, int32_t v) {
    napi_value out;
    napi_create_int32(env, v, &out);
    return out;
}

static bool GetInt32(napi_env env, napi_value v, int32_t *out) {
    return napi_get_value_int32(env, v, out) == napi_ok;
}

// ---------- 1. 距上次输入间隔（ms；INTERCEPT_INPUT_EVENT，失败返回负值错误码） ----------
static napi_value GetIntervalSinceLastInput(napi_env env, napi_callback_info info) {
    int64_t interval = -1;
    Input_Result ret = OH_Input_GetIntervalSinceLastInput(&interval);
    if (ret != INPUT_SUCCESS) {
        return MakeInt(env, -static_cast<int32_t>(ret));
    }
    napi_value out;
    napi_create_double(env, static_cast<double>(interval), &out);
    return out;
}

// ---------- 2/3/4. 光标样式与可见性（@22） ----------
static napi_value SetPointerStyle(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t windowId = -1, style = 0;
    if (argc < 2 || !GetInt32(env, args[0], &windowId) || !GetInt32(env, args[1], &style)) {
        return MakeInt(env, INPUT_PARAMETER_ERROR);
    }
    int32_t ret = OH_Input_SetPointerStyle(windowId, style);
    OH_LOG_INFO(LOG_APP, "SetPointerStyle win=%{public}d style=%{public}d ret=%{public}d", windowId, style, ret);
    return MakeInt(env, ret);
}

static napi_value GetPointerStyle(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t windowId = -1, style = -1;
    if (argc < 1 || !GetInt32(env, args[0], &windowId)) {
        return MakeInt(env, INPUT_PARAMETER_ERROR);
    }
    Input_Result ret = OH_Input_GetPointerStyle(windowId, &style);
    napi_value obj;
    napi_create_object(env, &obj);
    napi_set_named_property(env, obj, "code", MakeInt(env, static_cast<int32_t>(ret)));
    napi_set_named_property(env, obj, "style", MakeInt(env, style));
    return obj;
}

static napi_value SetPointerVisible(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t visible = 1;
    if (argc < 1 || !GetInt32(env, args[0], &visible)) {
        return MakeInt(env, INPUT_PARAMETER_ERROR);
    }
    int32_t ret = OH_Input_SetPointerVisible(visible != 0);
    OH_LOG_INFO(LOG_APP, "SetPointerVisible=%{public}d ret=%{public}d", visible, ret);
    return MakeInt(env, ret);
}

// ---------- 5/6. 全局鼠标事件监听（INPUT_MONITORING；TSFN 跨线程回调） ----------
struct MouseEventData {
    int32_t action;
    int32_t x;
    int32_t y;
    int32_t button;
    int32_t windowId;
};

static napi_threadsafe_function g_mouseTsfn = nullptr;

static void OnMouseEvent(const Input_MouseEvent *ev) {
    if (g_mouseTsfn == nullptr || ev == nullptr) {
        return;
    }
    MouseEventData *data = new MouseEventData{
        OH_Input_GetMouseEventAction(ev),
        OH_Input_GetMouseEventDisplayX(ev),
        OH_Input_GetMouseEventDisplayY(ev),
        OH_Input_GetMouseEventButton(ev),
        OH_Input_GetMouseEventWindowId(ev),
    };
    napi_call_threadsafe_function(g_mouseTsfn, data, napi_tsfn_nonblocking);
}

static void MouseCallJs(napi_env env, napi_value jsCb, void *context, void *raw) {
    (void)context;
    MouseEventData *data = static_cast<MouseEventData *>(raw);
    if (data == nullptr) {
        return;
    }
    napi_value obj;
    napi_create_object(env, &obj);
    napi_set_named_property(env, obj, "action", MakeInt(env, data->action));
    napi_set_named_property(env, obj, "x", MakeInt(env, data->x));
    napi_set_named_property(env, obj, "y", MakeInt(env, data->y));
    napi_set_named_property(env, obj, "button", MakeInt(env, data->button));
    napi_set_named_property(env, obj, "windowId", MakeInt(env, data->windowId));
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_value argv[1] = {obj};
    napi_call_function(env, undefined, jsCb, 1, argv, nullptr);
    delete data;
}

// startMouseMonitor(jsCallback) → Input_Result
static napi_value StartMouseMonitor(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return MakeInt(env, INPUT_PARAMETER_ERROR);
    }
    if (g_mouseTsfn == nullptr) {
        napi_value resourceName;
        napi_create_string_utf8(env, "dshMouseMonitor", NAPI_AUTO_LENGTH, &resourceName);
        napi_status st = napi_create_threadsafe_function(env, args[0], nullptr, resourceName, 0, 1,
                                                         nullptr, nullptr, nullptr, MouseCallJs, &g_mouseTsfn);
        if (st != napi_ok) {
            return MakeInt(env, INPUT_SERVICE_EXCEPTION);
        }
    }
    int32_t ret = OH_Input_AddMouseEventMonitor(OnMouseEvent);
    OH_LOG_INFO(LOG_APP, "AddMouseEventMonitor ret=%{public}d", ret);
    return MakeInt(env, ret);
}

static napi_value StopMouseMonitor(napi_env env, napi_callback_info info) {
    int32_t ret = OH_Input_RemoveMouseEventMonitor(OnMouseEvent);
    if (g_mouseTsfn != nullptr) {
        napi_release_threadsafe_function(g_mouseTsfn, napi_tsfn_release);
        g_mouseTsfn = nullptr;
    }
    OH_LOG_INFO(LOG_APP, "RemoveMouseEventMonitor ret=%{public}d", ret);
    return MakeInt(env, ret);
}

// ---------- 7/8. HiTrace 打点（自动化延迟诊断；打点名出现在系统 trace 中） ----------
static napi_value TraceBegin(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char name[128] = {0};
    size_t len = 0;
    if (argc < 1 || napi_get_value_string_utf8(env, args[0], name, sizeof(name) - 1, &len) != napi_ok || len == 0) {
        return MakeInt(env, INPUT_PARAMETER_ERROR);
    }
    OH_HiTrace_BeginChain(name, HITRACE_FLAG_DEFAULT);
    return MakeInt(env, 0);
}

static napi_value TraceEnd(napi_env env, napi_callback_info info) {
    OH_HiTrace_EndChain();
    return MakeInt(env, 0);
}

// ---------- 9. OH_AVScreenCapture 单帧截屏（异步，进程内 RGBA buffer） ----------
struct CaptureCtx {
    napi_async_work work;
    napi_deferred deferred;
    int32_t reqW;
    int32_t reqH;
    int32_t code;
    int32_t width;
    int32_t height;
    int32_t stride;
    std::vector<uint8_t> pixels;
};

static void DoCapture(CaptureCtx *ctx) {
    ctx->code = -1;
    OH_AVScreenCapture *capture = OH_AVScreenCapture_Create();
    if (capture == nullptr) {
        ctx->code = -2;
        return;
    }
    OH_AVScreenCaptureConfig config;
    memset(&config, 0, sizeof(config));
    config.captureMode = OH_CAPTURE_HOME_SCREEN;
    config.dataType = OH_ORIGINAL_STREAM;
    config.videoInfo.videoCapInfo.videoFrameWidth = ctx->reqW;
    config.videoInfo.videoCapInfo.videoFrameHeight = ctx->reqH;
    config.videoInfo.videoCapInfo.videoSource = OH_VIDEO_SOURCE_SURFACE_RGBA;
    config.videoInfo.videoEncInfo.videoCodec = OH_VIDEO_DEFAULT;
    config.videoInfo.videoEncInfo.videoFrameRate = 30;
    OH_AVScreenCapture_SetMicrophoneEnabled(capture, false);
    OH_AVSCREEN_CAPTURE_ErrCode ret = OH_AVScreenCapture_Init(capture, config);
    if (ret != AV_SCREEN_CAPTURE_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "capture Init ret=%{public}d", ret);
        ctx->code = static_cast<int32_t>(ret);
        OH_AVScreenCapture_Release(capture);
        return;
    }
    ret = OH_AVScreenCapture_StartScreenCapture(capture);
    if (ret != AV_SCREEN_CAPTURE_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "capture Start ret=%{public}d", ret);
        ctx->code = static_cast<int32_t>(ret);
        OH_AVScreenCapture_Release(capture);
        return;
    }
    // 轮询取首帧（AcquireVideoBuffer 无超时参数，取不到返回 nullptr）
    OH_NativeBuffer *buffer = nullptr;
    int fence = -1;
    int64_t timestamp = 0;
    OH_Rect region{0, 0, 0, 0};
    for (int i = 0; i < 60; i++) {
        buffer = OH_AVScreenCapture_AcquireVideoBuffer(capture, &fence, &timestamp, &region);
        if (buffer != nullptr) {
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    if (buffer == nullptr) {
        OH_LOG_ERROR(LOG_APP, "capture acquire video buffer timeout");
        ctx->code = -3;
        OH_AVScreenCapture_StopScreenCapture(capture);
        OH_AVScreenCapture_Release(capture);
        return;
    }
    OH_NativeBuffer_Config nbConfig;
    OH_NativeBuffer_GetConfig(buffer, &nbConfig);
    ctx->width = nbConfig.width;
    ctx->height = nbConfig.height;
    ctx->stride = nbConfig.stride > 0 ? nbConfig.stride : nbConfig.width * 4;
    void *virAddr = nullptr;
    if (OH_NativeBuffer_Map(buffer, &virAddr) == 0 && virAddr != nullptr) {
        size_t size = static_cast<size_t>(ctx->stride) * static_cast<size_t>(ctx->height);
        ctx->pixels.resize(size);
        memcpy(ctx->pixels.data(), virAddr, size);
        OH_NativeBuffer_Unmap(buffer);
        ctx->code = 0;
    } else {
        ctx->code = -4;
    }
    if (fence >= 0) {
        close(fence);
    }
    // 本 SDK（API 26）OH_AVScreenCapture_ReleaseVideoBuffer 只收 capture 单参数（98608bdc 修编译错误）
    OH_AVScreenCapture_ReleaseVideoBuffer(capture);
    OH_AVScreenCapture_StopScreenCapture(capture);
    OH_AVScreenCapture_Release(capture);
    OH_LOG_INFO(LOG_APP, "capture done code=%{public}d %{public}dx%{public}d stride=%{public}d",
                ctx->code, ctx->width, ctx->height, ctx->stride);
}

static void CaptureExecute(napi_env env, void *data) {
    (void)env;
    DoCapture(static_cast<CaptureCtx *>(data));
}

static void CaptureComplete(napi_env env, napi_status status, void *data) {
    (void)status;
    CaptureCtx *ctx = static_cast<CaptureCtx *>(data);
    napi_value obj;
    napi_create_object(env, &obj);
    napi_set_named_property(env, obj, "code", MakeInt(env, ctx->code));
    napi_set_named_property(env, obj, "width", MakeInt(env, ctx->width));
    napi_set_named_property(env, obj, "height", MakeInt(env, ctx->height));
    napi_set_named_property(env, obj, "stride", MakeInt(env, ctx->stride));
    napi_set_named_property(env, obj, "size", MakeInt(env, static_cast<int32_t>(ctx->pixels.size())));
    if (ctx->code == 0 && !ctx->pixels.empty()) {
        void *outBuf = nullptr;
        napi_value arrayBuffer;
        napi_create_arraybuffer(env, ctx->pixels.size(), &outBuf, &arrayBuffer);
        memcpy(outBuf, ctx->pixels.data(), ctx->pixels.size());
        napi_set_named_property(env, obj, "data", arrayBuffer);
    }
    napi_resolve_deferred(env, ctx->deferred, obj);
    napi_delete_async_work(env, ctx->work);
    delete ctx;
}

// captureScreenshot(width, height) → Promise<{code,width,height,stride,size,data?}>
static napi_value CaptureScreenshot(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    CaptureCtx *ctx = new CaptureCtx{};
    ctx->reqW = 1920;
    ctx->reqH = 1080;
    if (argc > 0) { GetInt32(env, args[0], &ctx->reqW); }
    if (argc > 1) { GetInt32(env, args[1], &ctx->reqH); }
    napi_value promise;
    napi_create_promise(env, &ctx->deferred, &promise);
    napi_value resourceName;
    napi_create_string_utf8(env, "dshCapture", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, CaptureExecute, CaptureComplete, ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

// ---------- 模块注册（与 napi_input.cpp 共注册到同一 exports） ----------
napi_value RegisterDshNativeExtras(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"getIntervalSinceLastInput", nullptr, GetIntervalSinceLastInput, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setPointerStyle", nullptr, SetPointerStyle, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getPointerStyle", nullptr, GetPointerStyle, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setPointerVisible", nullptr, SetPointerVisible, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startMouseMonitor", nullptr, StartMouseMonitor, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopMouseMonitor", nullptr, StopMouseMonitor, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"traceBegin", nullptr, TraceBegin, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"traceEnd", nullptr, TraceEnd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"captureScreenshot", nullptr, CaptureScreenshot, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
