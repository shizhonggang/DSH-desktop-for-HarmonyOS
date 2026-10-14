/**
 * dshnative —— NDK 窗口能力 v3（session-43e17adf）
 *
 * 三个新能力（权限均为 CUSTOM_SCREEN_CAPTURE，user_grant，本机已授权）：
 *  - getAllMainWindows   OH_WindowManager_GetAllMainWindowInfo(@21)
 *                        → 所有主窗 {displayId, windowId, showing(前后台), label(任务名)}
 *  - captureWindow       OH_WindowManager_GetMainWindowSnapshot(@21)
 *                        → 按 windowId 截任意主窗，回调返回 Pixelmap，读成 RGBA
 *  - captureDisplay      OH_NativeDisplayManager_CaptureScreenPixelmap(@14)
 *                        → 一步整屏 Pixelmap（比 AVScreenCapture pipeline 轻）
 *
 * 返回约定：capture* 返回 {code,width,height,stride,format,size,data:ArrayBuffer}
 *          getAllMainWindows 返回 {code,count,windows:[...]}
 */
#include <napi/native_api.h>
#include <window_manager/oh_window.h>
#include <window_manager/oh_window_comm.h>
#include <window_manager/oh_display_manager.h>
#include <window_manager/oh_display_capture.h>
#include <multimedia/image_framework/image/pixelmap_native.h>
#include <AbilityKit/native_child_process.h>
#include <hilog/log.h>
#include <cstring>
#include <vector>
#include <mutex>
#include <atomic>
#include <condition_variable>
#include <chrono>

#define LOG_DOMAIN 0xD513
#define LOG_TAG "dshnative-v3"

static napi_value V3MakeInt(napi_env env, int32_t v) {
    napi_value out;
    napi_create_int32(env, v, &out);
    return out;
}

// ---------- 1. 所有主窗信息（label + 前后台） ----------
// getAllMainWindows() → {code, count, windows:[{displayId, windowId, showing, label}]}
static napi_value GetAllMainWindows(napi_env env, napi_callback_info info) {
    WindowManager_MainWindowInfo *list = nullptr;
    size_t size = 0;
    int32_t ret = OH_WindowManager_GetAllMainWindowInfo(&list, &size);
    napi_value obj;
    napi_create_object(env, &obj);
    napi_set_named_property(env, obj, "code", V3MakeInt(env, ret));
    napi_value arr;
    napi_create_array(env, &arr);
    uint32_t n = 0;
    if (ret == 0 && list != nullptr) {
        for (size_t i = 0; i < size; i++) {
            napi_value item;
            napi_create_object(env, &item);
            napi_value v;
            napi_create_double(env, static_cast<double>(list[i].displayId), &v);
            napi_set_named_property(env, item, "displayId", v);
            napi_set_named_property(env, item, "windowId", V3MakeInt(env, list[i].windowId));
            napi_get_boolean(env, list[i].showing, &v);
            napi_set_named_property(env, item, "showing", v);
            napi_create_string_utf8(env, list[i].label == nullptr ? "" : list[i].label, NAPI_AUTO_LENGTH, &v);
            napi_set_named_property(env, item, "label", v);
            napi_set_element(env, arr, n++, item);
        }
        OH_WindowManager_ReleaseAllMainWindowInfo(list);
    }
    napi_set_named_property(env, obj, "count", V3MakeInt(env, static_cast<int32_t>(n)));
    napi_set_named_property(env, obj, "windows", arr);
    OH_LOG_INFO(LOG_APP, "GetAllMainWindows ret=%{public}d count=%{public}u", ret, n);
    return obj;
}

// ---------- 公共：Pixelmap → RGBA 拷贝 ----------
static bool CopyPixelmapToVector(OH_PixelmapNative *pm, std::vector<uint8_t> &out,
                                 int32_t &w, int32_t &h, int32_t &stride, int32_t &fmt, int32_t &code) {
    if (pm == nullptr) {
        code = -2;
        return false;
    }
    OH_Pixelmap_ImageInfo *info = nullptr;
    if (OH_PixelmapImageInfo_Create(&info) != IMAGE_SUCCESS || info == nullptr) {
        code = -3;
        return false;
    }
    uint32_t uw = 0, uh = 0, ustride = 0;
    int32_t pfmt = 0;
    OH_PixelmapNative_GetImageInfo(pm, info);
    OH_PixelmapImageInfo_GetWidth(info, &uw);
    OH_PixelmapImageInfo_GetHeight(info, &uh);
    OH_PixelmapImageInfo_GetRowStride(info, &ustride);
    OH_PixelmapImageInfo_GetPixelFormat(info, &pfmt);
    w = static_cast<int32_t>(uw);
    h = static_cast<int32_t>(uh);
    stride = ustride > 0 ? static_cast<int32_t>(ustride) : static_cast<int32_t>(uw) * 4;
    fmt = pfmt;
    size_t need = static_cast<size_t>(stride) * static_cast<size_t>(h);
    out.resize(need);
    size_t bufSize = need;
    Image_ErrorCode rd = OH_PixelmapNative_ReadPixels(pm, out.data(), &bufSize);
    OH_PixelmapImageInfo_Release(info);
    if (rd != IMAGE_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "ReadPixels failed %{public}d", rd);
        code = static_cast<int32_t>(rd);
        return false;
    }
    out.resize(bufSize);
    // ⚠️ 实测陷阱（2026-10-12）：ReadPixels 输出是**紧密排列**（w*4 字节/行），
    // 而 OH_PixelmapImageInfo_GetRowStride 可能报含填充的值
    // （窗口宽 2082 时报 stride=8448，实际数据 8328/行；按 8448 解码 → 整图错位成噪声）。
    // 统一归一化为紧密布局，调用方无需理解 stride 语义。
    size_t packed = static_cast<size_t>(w) * 4 * static_cast<size_t>(h);
    if (bufSize >= packed) {
        out.resize(packed);
        stride = w * 4;
    }
    code = 0;
    return true;
}

struct ShotCtx {
    napi_async_work work;
    napi_deferred deferred;
    int32_t code;
    int32_t width;
    int32_t height;
    int32_t stride;
    int32_t format;
    std::vector<uint8_t> pixels;
};

static void ResolveShot(napi_env env, ShotCtx *ctx) {
    napi_value obj;
    napi_create_object(env, &obj);
    napi_set_named_property(env, obj, "code", V3MakeInt(env, ctx->code));
    napi_set_named_property(env, obj, "width", V3MakeInt(env, ctx->width));
    napi_set_named_property(env, obj, "height", V3MakeInt(env, ctx->height));
    napi_set_named_property(env, obj, "stride", V3MakeInt(env, ctx->stride));
    napi_set_named_property(env, obj, "format", V3MakeInt(env, ctx->format));
    napi_set_named_property(env, obj, "size", V3MakeInt(env, static_cast<int32_t>(ctx->pixels.size())));
    if (ctx->code == 0 && !ctx->pixels.empty()) {
        void *buf = nullptr;
        napi_value ab;
        napi_create_arraybuffer(env, ctx->pixels.size(), &buf, &ab);
        memcpy(buf, ctx->pixels.data(), ctx->pixels.size());
        napi_set_named_property(env, obj, "data", ab);
    }
    napi_resolve_deferred(env, ctx->deferred, obj);
    napi_delete_async_work(env, ctx->work);
    delete ctx;
}

// ---------- 2. 整屏截图（轻量） ----------
// captureDisplay(displayId) → Promise<shot>；displayId 传 0 用默认屏
static void DisplayCaptureExecute(napi_env env, void *data) {
    (void)env;
    ShotCtx *ctx = static_cast<ShotCtx *>(data);
    OH_PixelmapNative *pm = nullptr;
    int32_t ret = static_cast<int32_t>(OH_NativeDisplayManager_CaptureScreenPixelmap(0, &pm));
    ctx->code = ret;
    if (ret != 0 || pm == nullptr) {
        OH_LOG_ERROR(LOG_APP, "CaptureScreenPixelmap ret=%{public}d", ret);
        return;
    }
    int32_t c = 0;
    CopyPixelmapToVector(pm, ctx->pixels, ctx->width, ctx->height, ctx->stride, ctx->format, c);
    ctx->code = c;
    OH_PixelmapNative_Release(pm);
    OH_LOG_INFO(LOG_APP, "captureDisplay done code=%{public}d %{public}dx%{public}d stride=%{public}d fmt=%{public}d",
                ctx->code, ctx->width, ctx->height, ctx->stride, ctx->format);
}

static napi_value CaptureDisplay(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    ShotCtx *ctx = new ShotCtx{};
    ctx->code = -1;
    napi_value promise;
    napi_create_promise(env, &ctx->deferred, &promise);
    napi_value rn;
    napi_create_string_utf8(env, "dshDisplayCapture", NAPI_AUTO_LENGTH, &rn);
    napi_create_async_work(env, nullptr, rn, DisplayCaptureExecute, [](napi_env e, napi_status, void *d) {
        ResolveShot(e, static_cast<ShotCtx *>(d));
    }, ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

// ---------- 3. 按窗截图 ----------
// captureWindow(windowId, width, height) → Promise<shot>
// ⚠️ 设计纪律（2026-10-12 踩坑）：系统回调里**只存指针、不做任何 Pixelmap 操作**——
// 首版在回调里直接 GetImageInfo/ReadPixels，把应用主线程卡死（agent 停止轮询、无 crash 记录）。
struct WindowShotState {
    std::mutex m;
    std::condition_variable cv;
    bool done = false;
    const OH_PixelmapNative **list = nullptr;   // 回调给的列表（读完用 Release 释放）
    size_t listSize = 0;
    std::vector<uint8_t> pixels;
    int32_t code = -1;
    int32_t width = 0;
    int32_t height = 0;
    int32_t stride = 0;
    int32_t format = 0;
};

static WindowShotState g_windowShot;
static std::mutex g_windowShotLock;   // 同一时刻只允许一个按窗截图
static std::atomic<bool> g_windowShotBusy{false}; // 并发闸：第二次调用直接拒，不排队（防线程池占满）

static void OnWindowSnapshot(const OH_PixelmapNative **list, size_t size) {
    std::lock_guard<std::mutex> lk(g_windowShot.m);
    g_windowShot.list = list;
    g_windowShot.listSize = size;
    g_windowShot.done = true;
    g_windowShot.cv.notify_all();
}

// 参数打包：windowId + width + height
struct WindowCaptureArgs {
    ShotCtx *ctx;
    int32_t windowId;
    int32_t width;
    int32_t height;
};

static void WindowCaptureExecute2(napi_env env, void *data) {
    (void)env;
    WindowCaptureArgs *a = static_cast<WindowCaptureArgs *>(data);
    ShotCtx *ctx = a->ctx;
    std::lock_guard<std::mutex> guard(g_windowShotLock);
    {
        std::lock_guard<std::mutex> lk(g_windowShot.m);
        g_windowShot.done = false;
        g_windowShot.list = nullptr;
        g_windowShot.listSize = 0;
        g_windowShot.pixels.clear();
        g_windowShot.code = -1;
    }
    WindowManager_WindowSnapshotConfig config;
    memset(&config, 0, sizeof(config));
    // 本 SDK 的 config 只有 useCache（截图尺寸自动跟随窗口）；
    // useCache=false → 强制抓最新帧（true 在无缓存时行为不确定）
    config.useCache = false;
    int32_t ids[1] = {a->windowId};
    int32_t ret = OH_WindowManager_GetMainWindowSnapshot(ids, 1, config, OnWindowSnapshot);
    if (ret != 0) {
        ctx->code = ret;
        OH_LOG_ERROR(LOG_APP, "GetMainWindowSnapshot ret=%{public}d win=%{public}d", ret, a->windowId);
        g_windowShotBusy.store(false);
        return;
    }
    const OH_PixelmapNative **list = nullptr;
    size_t listSize = 0;
    bool got = false;
    {
        std::unique_lock<std::mutex> lk(g_windowShot.m);
        g_windowShot.cv.wait_for(lk, std::chrono::seconds(5), [] { return g_windowShot.done; });
        got = g_windowShot.done && g_windowShot.list != nullptr && g_windowShot.listSize > 0;
        list = g_windowShot.list;
        listSize = g_windowShot.listSize;
    }
    if (!got) {
        ctx->code = g_windowShot.done ? -4 : -5;   // -4=空列表 -5=超时
        if (list != nullptr) {
            OH_WindowManager_ReleaseMainWindowSnapshot(reinterpret_cast<const OH_PixelmapNative *>(list));
        }
        OH_LOG_ERROR(LOG_APP, "captureWindow no frame code=%{public}d", ctx->code);
        g_windowShotBusy.store(false);
        return;
    }
    // 回调已返回，这里（worker 线程）才做 Pixelmap 读取
    int32_t c = 0;
    if (CopyPixelmapToVector(const_cast<OH_PixelmapNative *>(list[0]), ctx->pixels,
                             ctx->width, ctx->height, ctx->stride, ctx->format, c)) {
        ctx->code = 0;
    } else {
        ctx->code = c;
    }
    OH_WindowManager_ReleaseMainWindowSnapshot(reinterpret_cast<const OH_PixelmapNative *>(list));
    OH_LOG_INFO(LOG_APP, "captureWindow done code=%{public}d win=%{public}d %{public}dx%{public}d fmt=%{public}d",
                ctx->code, a->windowId, ctx->width, ctx->height, ctx->format);
    g_windowShotBusy.store(false);
}

static napi_value CaptureWindow(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t windowId = 0, width = 0, height = 0;
    if (argc < 1 || napi_get_value_int32(env, args[0], &windowId) != napi_ok) {
        return V3MakeInt(env, 401);
    }
    if (argc > 1) { napi_get_value_int32(env, args[1], &width); }
    if (argc > 2) { napi_get_value_int32(env, args[2], &height); }
    // 并发闸：同一时刻只允许一个按窗截图（避免多个 worker 同时等回调）
    if (g_windowShotBusy.load()) {
        return V3MakeInt(env, -6);
    }
    g_windowShotBusy.store(true);
    ShotCtx *ctx = new ShotCtx{};
    ctx->code = -1;
    WindowCaptureArgs *a = new WindowCaptureArgs{ctx, windowId, width, height};
    napi_value promise;
    napi_create_promise(env, &ctx->deferred, &promise);
    napi_value rn;
    napi_create_string_utf8(env, "dshWindowCapture", NAPI_AUTO_LENGTH, &rn);
    napi_create_async_work(env, nullptr, rn, WindowCaptureExecute2, [](napi_env e, napi_status, void *d) {
        WindowCaptureArgs *aa = static_cast<WindowCaptureArgs *>(d);
        ShotCtx *c = aa->ctx;
        ResolveShot(e, c);
        delete aa;
    }, a, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

// ---------- 4. NativeChildProcess 可用性探针（评估用） ----------
// 用**不存在的 lib 名**探测机制门槛：关注返回值而非子进程本身——
//   0            = NCP_NO_ERROR：机制可用（随后回调会报 dlopen 失败，属预期）
//   801          = NCP_ERR_NOT_SUPPORTED：设备不支持 native 子进程
//   16010004     = NCP_ERR_MULTI_PROCESS_DISABLED：设备多进程模式被禁用
//   16010005     = NCP_ERR_ALREADY_IN_CHILD：当前已在子进程中
//   16010006     = NCP_ERR_MAX_CHILD_PROCESSES_REACHED：达到上限
// 回调在独立线程，结果记 hilog（异步，桥侧只回同步返回码）。
static std::atomic<int32_t> g_childProbeCallbackCode{-999};

static napi_value ProbeNativeChildProcess(napi_env env, napi_callback_info info) {
    g_childProbeCallbackCode.store(-999);
    int ret = OH_Ability_CreateNativeChildProcess(
        "libdshnative_childprobe_does_not_exist.so",
        [](int errCode, OHIPCRemoteProxy *proxy) {
            (void)proxy;
            g_childProbeCallbackCode.store(errCode);
            OH_LOG_INFO(LOG_APP, "child process started callback errCode=%{public}d", errCode);
        });
    OH_LOG_INFO(LOG_APP, "CreateNativeChildProcess probe ret=%{public}d", ret);
    napi_value obj;
    napi_create_object(env, &obj);
    napi_set_named_property(env, obj, "ret", V3MakeInt(env, ret));
    napi_set_named_property(env, obj, "callbackCode", V3MakeInt(env, g_childProbeCallbackCode.load()));
    return obj;
}

// ---------- 注册 ----------
napi_value RegisterDshNativeV3(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"getAllMainWindows", nullptr, GetAllMainWindows, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"captureDisplay", nullptr, CaptureDisplay, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"captureWindow", nullptr, CaptureWindow, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"probeNativeChildProcess", nullptr, ProbeNativeChildProcess, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
