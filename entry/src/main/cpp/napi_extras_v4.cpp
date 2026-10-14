/**
 * dshnative —— NDK 离屏渲染 v4（session-43e17adf）
 *
 * 背景：ArkTS 的 componentSnapshot.createFromBuilder 在**非组件宿主**上下文必炸
 * （Cannot read property observeComponentCreation2 of undefined），本 SDK 又无
 * createFromComponentContent → 改用纯 NDK 绘制，零组件树、零宿主、连窗口都不需要。
 *
 * 链路：OH_Drawing_Bitmap(离屏位图) → Canvas(画布) → Brush/圆角矩形/TextBlob 文本
 *      → BitmapGetPixels → OH_PixelmapNative_CreatePixelmap
 *      → OH_ImagePackerNative_PackToFileFromPixelmap(**直接写 fd**，无需猜 PNG 缓冲大小)
 *
 * 注意：PackToDataFromPixelmap 的 outData 是**调用方提供**的缓冲（无长度查询 API），
 * 所以这里选 PackToFile* 走 fd —— 由 ArkTS 侧开文件、传 fd 进来。
 */
#include <napi/native_api.h>
#include <native_drawing/drawing_bitmap.h>
#include <native_drawing/drawing_canvas.h>
#include <native_drawing/drawing_brush.h>
#include <native_drawing/drawing_pen.h>
#include <native_drawing/drawing_font.h>
#include <native_drawing/drawing_text_blob.h>
#include <native_drawing/drawing_rect.h>
#include <native_drawing/drawing_round_rect.h>
#include <native_drawing/drawing_color.h>
#include <native_drawing/drawing_typeface.h>
#include <native_drawing/drawing_types.h>
#include <multimedia/image_framework/image/pixelmap_native.h>
#include <multimedia/image_framework/image/image_packer_native.h>
#include <hilog/log.h>
#include <cstring>

#define LOG_DOMAIN 0xD514
#define LOG_TAG "dshnative-v4"

static napi_value V4MakeInt(napi_env env, int32_t v) {
    napi_value out;
    napi_create_int32(env, v, &out);
    return out;
}

static bool V4GetInt(napi_env env, napi_value v, int32_t *out) {
    return napi_get_value_int32(env, v, out) == napi_ok;
}

/**
 * renderCardToFd(fd, width, height, title, subtitle, accentArgb)
 *   → {code, width, height, titleLen, subtitleLen}
 * 画一张卡片（圆角底 + 标题 + 副标题）并把 PNG 直接写进 fd。
 * accentArgb 用 OH_Drawing_ColorSetArgb 生成的 32 位 ARGB；传 0 用默认蓝。
 */
static napi_value RenderCardToFd(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t fd = -1, width = 720, height = 320, accent = 0;
    if (argc < 1 || !V4GetInt(env, args[0], &fd) || fd < 0) {
        return V4MakeInt(env, 401);
    }
    if (argc > 1) { V4GetInt(env, args[1], &width); }
    if (argc > 2) { V4GetInt(env, args[2], &height); }
    if (argc > 5) { V4GetInt(env, args[5], &accent); }
    if (width <= 0 || height <= 0 || width > 4096 || height > 4096) {
        return V4MakeInt(env, 401);
    }
    char title[256] = {0};
    char subtitle[256] = {0};
    size_t tlen = 0, slen = 0;
    if (argc > 3) {
        napi_get_value_string_utf8(env, args[3], title, sizeof(title) - 1, &tlen);
    }
    if (argc > 4) {
        napi_get_value_string_utf8(env, args[4], subtitle, sizeof(subtitle) - 1, &slen);
    }

    int32_t code = 0;
    // 1) 离屏位图 + 画布
    OH_Drawing_Bitmap *bitmap = OH_Drawing_BitmapCreate();
    OH_Drawing_BitmapFormat fmt;
    memset(&fmt, 0, sizeof(fmt));
    // ⚠️ OH_Drawing_ColorSetArgb 产出 32 位 ARGB，落进内存是小端 → 字节序 B,G,R,A。
    // 若按 RGBA_8888 声明位图/Pixelmap，颜色 R/B 会互换（实测：想要的蓝 #1A73E8 渲染成橙 #E8731A）。
    fmt.colorFormat = COLOR_FORMAT_BGRA_8888;
    fmt.alphaFormat = ALPHA_FORMAT_PREMUL;
    OH_Drawing_BitmapBuild(bitmap, static_cast<uint32_t>(width), static_cast<uint32_t>(height), &fmt);
    OH_Drawing_Canvas *canvas = OH_Drawing_CanvasCreate();
    OH_Drawing_CanvasBind(canvas, bitmap);
    OH_Drawing_CanvasClear(canvas, OH_Drawing_ColorSetArgb(0xFF, 0x00, 0x00, 0x00));

    // 2) 圆角底
    OH_Drawing_Brush *bg = OH_Drawing_BrushCreate();
    OH_Drawing_BrushSetColor(bg, accent != 0 ? static_cast<uint32_t>(accent)
                                             : OH_Drawing_ColorSetArgb(0xFF, 0x1A, 0x73, 0xE8));
    OH_Drawing_Rect *rect = OH_Drawing_RectCreate(0, 0, static_cast<float>(width), static_cast<float>(height));
    OH_Drawing_RoundRect *round = OH_Drawing_RoundRectCreate(rect, 24.0f, 24.0f);
    OH_Drawing_CanvasAttachBrush(canvas, bg);
    OH_Drawing_CanvasDrawRoundRect(canvas, round);
    OH_Drawing_CanvasDetachBrush(canvas);

    // 3) 文本（默认字体，UTF-8；中文由系统默认字体覆盖）
    OH_Drawing_Typeface *typeface = OH_Drawing_TypefaceCreateDefault();
    OH_Drawing_Font *font = OH_Drawing_FontCreate();
    if (typeface != nullptr) {
        OH_Drawing_FontSetTypeface(font, typeface);
    }
    OH_Drawing_Brush *fg = OH_Drawing_BrushCreate();
    OH_Drawing_BrushSetColor(fg, OH_Drawing_ColorSetArgb(0xFF, 0xFF, 0xFF, 0xFF));
    OH_Drawing_CanvasAttachBrush(canvas, fg);
    if (tlen > 0) {
        OH_Drawing_FontSetTextSize(font, 34.0f);
        OH_Drawing_TextBlob *blob = OH_Drawing_TextBlobCreateFromString(title, font, TEXT_ENCODING_UTF8);
        if (blob != nullptr) {
            OH_Drawing_CanvasDrawTextBlob(canvas, blob, 32.0f, 84.0f);
            OH_Drawing_TextBlobDestroy(blob);
        }
    }
    if (slen > 0) {
        OH_Drawing_BrushSetColor(fg, OH_Drawing_ColorSetArgb(0xCC, 0xE8, 0xF0, 0xFE));
        OH_Drawing_CanvasDetachBrush(canvas);
        OH_Drawing_CanvasAttachBrush(canvas, fg);
        OH_Drawing_FontSetTextSize(font, 20.0f);
        OH_Drawing_TextBlob *blob2 = OH_Drawing_TextBlobCreateFromString(subtitle, font, TEXT_ENCODING_UTF8);
        if (blob2 != nullptr) {
            OH_Drawing_CanvasDrawTextBlob(canvas, blob2, 32.0f, 128.0f);
            OH_Drawing_TextBlobDestroy(blob2);
        }
    }
    OH_Drawing_CanvasDetachBrush(canvas);

    // 4) 位图 → Pixelmap
    void *pixels = OH_Drawing_BitmapGetPixels(bitmap);
    OH_Pixelmap_InitializationOptions *popts = nullptr;
    OH_PixelmapInitializationOptions_Create(&popts);
    OH_PixelmapInitializationOptions_SetWidth(popts, static_cast<uint32_t>(width));
    OH_PixelmapInitializationOptions_SetHeight(popts, static_cast<uint32_t>(height));
    OH_PixelmapInitializationOptions_SetPixelFormat(popts, PIXEL_FORMAT_BGRA_8888);
    OH_PixelmapInitializationOptions_SetAlphaType(popts, PIXELMAP_ALPHA_TYPE_PREMULTIPLIED);
    OH_PixelmapNative *pixelmap = nullptr;
    Image_ErrorCode pmRet = OH_PixelmapNative_CreatePixelmap(
        static_cast<uint8_t *>(pixels),
        static_cast<size_t>(width) * static_cast<size_t>(height) * 4,
        popts, &pixelmap);
    if (pmRet != IMAGE_SUCCESS || pixelmap == nullptr) {
        code = static_cast<int32_t>(pmRet);
        OH_LOG_ERROR(LOG_APP, "CreatePixelmap failed %{public}d", pmRet);
    } else {
        // 5) PNG 直接写 fd
        OH_ImagePackerNative *packer = nullptr;
        OH_ImagePackerNative_Create(&packer);
        OH_PackingOptions *opts = nullptr;
        OH_PackingOptions_Create(&opts);
        // Image_MimeType = struct Image_String { char* data; size_t size; }
        Image_MimeType mime;
        mime.data = const_cast<char *>("image/png");
        mime.size = 9;   // strlen("image/png")
        OH_PackingOptions_SetMimeType(opts, &mime);
        OH_PackingOptions_SetQuality(opts, 95);
        Image_ErrorCode pk = OH_ImagePackerNative_PackToFileFromPixelmap(packer, opts, pixelmap, fd);
        if (pk != IMAGE_SUCCESS) {
            code = static_cast<int32_t>(pk);
            OH_LOG_ERROR(LOG_APP, "PackToFileFromPixelmap failed %{public}d", pk);
        }
        OH_PackingOptions_Release(opts);
        OH_ImagePackerNative_Release(packer);
        OH_PixelmapNative_Release(pixelmap);
    }
    OH_PixelmapInitializationOptions_Release(popts);
    OH_Drawing_TypefaceDestroy(typeface);
    OH_Drawing_FontDestroy(font);
    OH_Drawing_BrushDestroy(fg);
    OH_Drawing_BrushDestroy(bg);
    OH_Drawing_RoundRectDestroy(round);
    OH_Drawing_RectDestroy(rect);
    OH_Drawing_CanvasDestroy(canvas);
    OH_Drawing_BitmapDestroy(bitmap);
    OH_LOG_INFO(LOG_APP, "renderCardToFd code=%{public}d %{public}dx%{public}d titleLen=%{public}u",
                code, width, height, static_cast<unsigned>(tlen));

    napi_value out;
    napi_create_object(env, &out);
    napi_set_named_property(env, out, "code", V4MakeInt(env, code));
    napi_set_named_property(env, out, "width", V4MakeInt(env, width));
    napi_set_named_property(env, out, "height", V4MakeInt(env, height));
    napi_set_named_property(env, out, "titleLen", V4MakeInt(env, static_cast<int32_t>(tlen)));
    napi_set_named_property(env, out, "subtitleLen", V4MakeInt(env, static_cast<int32_t>(slen)));
    return out;
}

napi_value RegisterDshNativeV4(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"renderCardToFd", nullptr, RenderCardToFd, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
