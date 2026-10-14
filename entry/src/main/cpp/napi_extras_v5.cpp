/**
 * dshnative —— HID DDK 探针 v5（session-43e17adf，2026-10-12）
 *
 * 目的：把"能不能读外接 HID"从推断变成事实。两步问清：
 *   1) OH_Hid_Open 的返回码 → 201 说明缺 ACCESS_DDK_HID（system_basic，需 ACL）
 *   2) 若打开成功 → 非阻塞读一次，把原始报文字节 dump 出来（对比 Apple 私有协议）
 *
 * 目标设备：Apple Magic Trackpad 2（DDK 枚举实测 VID_05AC / PID_0265，busType=1 USB）
 */
#include <napi/native_api.h>
#include <hid/hid_ddk_api.h>
#include <hid/hid_ddk_types.h>
#include <hilog/log.h>
#include <cstring>
#include <cstdio>

#define LOG_DOMAIN 0xD515
#define LOG_TAG "dshnative-hid"

static napi_value HidMakeInt(napi_env env, int32_t v) {
    napi_value out;
    napi_create_int32(env, v, &out);
    return out;
}

/**
 * hidProbe(deviceId: number, interfaceIndex: number) → {
 *   init, open, read, bytesRead, vendor, product, busType, hex
 * }
 * init/open/read 为各阶段返回码（0=成功；201=缺 ACCESS_DDK_HID；801=不支持）
 */
static napi_value HidProbe(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t deviceId = 0;
    int32_t interfaceIndex = 0;
    if (argc < 1) {
        return HidMakeInt(env, 401);
    }
    napi_get_value_int64(env, args[0], &deviceId);
    if (argc > 1) {
        napi_get_value_int32(env, args[1], &interfaceIndex);
    }

    napi_value out;
    napi_create_object(env, &out);
    napi_value devIdVal;
    napi_create_double(env, static_cast<double>(deviceId), &devIdVal);
    napi_set_named_property(env, out, "deviceId", devIdVal);

    int32_t initRet = OH_Hid_Init();
    napi_set_named_property(env, out, "init", HidMakeInt(env, initRet));
    if (initRet != 0) {
        OH_LOG_ERROR(LOG_APP, "OH_Hid_Init ret=%{public}d", initRet);
        return out;
    }

    Hid_DeviceHandle *dev = nullptr;
    int32_t openRet = OH_Hid_Open(static_cast<uint64_t>(deviceId),
                                  static_cast<uint8_t>(interfaceIndex), &dev);
    napi_set_named_property(env, out, "open", HidMakeInt(env, openRet));
    OH_LOG_INFO(LOG_APP, "OH_Hid_Open(dev=%{public}lld, if=%{public}d) ret=%{public}d",
                static_cast<long long>(deviceId), interfaceIndex, openRet);
    if (openRet != 0 || dev == nullptr) {
        OH_Hid_Release();
        return out;
    }

    // 设备原始信息（VID/PID/总线）
    Hid_RawDevInfo rawInfo;
    memset(&rawInfo, 0, sizeof(rawInfo));
    if (OH_Hid_GetRawInfo(dev, &rawInfo) == 0) {
        napi_set_named_property(env, out, "vendor", HidMakeInt(env, rawInfo.vendor));
        napi_set_named_property(env, out, "product", HidMakeInt(env, rawInfo.product));
        napi_set_named_property(env, out, "busType", HidMakeInt(env, static_cast<int32_t>(rawInfo.busType)));
    }

    // 非阻塞读一次：拿到就是原始 HID 报文
    OH_Hid_SetNonBlocking(dev, 1);
    uint8_t buf[256];
    memset(buf, 0, sizeof(buf));
    uint32_t bytesRead = 0;
    int32_t readRet = OH_Hid_Read(dev, buf, sizeof(buf), &bytesRead);
    napi_set_named_property(env, out, "read", HidMakeInt(env, readRet));
    napi_set_named_property(env, out, "bytesRead", HidMakeInt(env, static_cast<int32_t>(bytesRead)));
    if (readRet == 0 && bytesRead > 0) {
        char hex[3 * 64 + 1];
        size_t n = bytesRead < 64 ? bytesRead : 64;
        for (size_t i = 0; i < n; i++) {
            snprintf(hex + i * 3, 4, "%02x ", buf[i]);
        }
        hex[n * 3] = '\0';
        napi_value hv;
        napi_create_string_utf8(env, hex, NAPI_AUTO_LENGTH, &hv);
        napi_set_named_property(env, out, "hex", hv);
        OH_LOG_INFO(LOG_APP, "HID read %{public}u bytes: %{public}s", bytesRead, hex);
    } else {
        OH_LOG_INFO(LOG_APP, "HID read ret=%{public}d bytes=%{public}u", readRet, bytesRead);
    }

    OH_Hid_Close(&dev);
    OH_Hid_Release();
    return out;
}

napi_value RegisterDshNativeV5(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"hidProbe", nullptr, HidProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
