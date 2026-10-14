# DSH native 模块：NDK-only 自动化能力（输入注入/光标/指针）
# 背景：这些能力在 ArkTS 层没有模块（CC knowledge/14 §八.B），只能走 NDK。
cmake_minimum_required(VERSION 3.16)
project(dshnative)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
include_directories(${NATIVERENDER_ROOT_PATH})

add_library(dshnative SHARED napi_input.cpp napi_extras.cpp napi_extras_v3.cpp napi_extras_v4.cpp napi_extras_v5.cpp)

# libohinput: OH_Input_*（注入/指针/修饰键/触点/监听）
# libnative_window_manager: OH_WindowManager_*（光标锁/主窗信息/按窗截图）+ OH_NativeDisplayManager_*
# libpixelmap: OH_PixelmapNative_*/OH_PixelmapImageInfo_*（Pixelmap 读像素）
# libhitrace_ndk.z: OH_HiTrace_*（自动化延迟打点）
# libnative_avscreen_capture: OH_AVScreenCapture_*（进程内截屏）
# libace_napi.z: napi 运行时；libhilog_ndk.z: 日志
target_link_libraries(dshnative PUBLIC
    libace_napi.z.so
    libohinput.so
    libnative_window_manager.so
    libnative_display_manager.so
    libpixelmap.so
    libchild_process.so
    libhid.z.so
    libnative_drawing.so
    libimage_packer.so
    libhitrace_ndk.z.so
    libnative_avscreen_capture.so
    libnative_buffer.so
    libnative_media_core.so
    libhilog_ndk.z.so
)
