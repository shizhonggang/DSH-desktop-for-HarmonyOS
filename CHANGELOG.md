# Changelog

本仓库所有值得记录的变更。格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，
版本遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [1.2.0] - 2026-09-16

### 新增

- **macOS 风格窗口控制按钮**：隐藏 HarmonyOS 原生标题栏按钮后，在左上角绘制红/黄/绿
  三个圆形按钮；hover 时显示 `×`、`−` 和绿色系统 SymbolGlyph 图标。
- **侧边栏联动**：通过注入脚本观察 DSH 侧边栏折叠状态，侧边栏收起时红绿灯同步隐藏。
- **顶部拖拽热区增强**：热区高度 28，宽度排除右侧 220vp；双击热区可最大化 / 还原窗口。
- **JS Bridge 扩展**：新增 `toggleMaximize` 与 `setSidebarCollapsed`。
- **窗口控制 API**：最大化 / 还原改用系统 `window.maximize()` / `window.recover()`。

### 修复

- **兼容 dsh web 的 token 认证**：dsh web 每次启动生成随机 token，WebView 裸连会被
  401 拒绝。
  - `EntryAbility` 支持读取启动参数 `dsh_token` 并存入 AppStorage；
  - `Index.ets` 首次加载带 `?token=…` 完成一次性认证握手（换取 30 天有效 cookie），
    之后免 token 直连；
  - 新增 `launch-local.sh`：鸿蒙本机启动辅助，自动解析 dsh web 输出中的 token 并传给应用；
  - 新增 `scripts/dsh-client-connection-loopback.patch`：给 dsh web 打本地回环免认证
    补丁后，本应用可完全免 token 接入（首页与 `/api` 均放行），见 README。
- **顶部热区过宽**：不再覆盖全宽，避免遮挡 DSH 右上角图标。
- **双击窗口化异常**：修复双击热区后无法正确恢复窗口、位置和大小异常的问题。
- **绿色按钮图标**：避免 SymbolGlyph 溢出或缺失，使用系统 SymbolGlyph 并限制字号。

### 变更

- `dsh-desktop-platform` 标记改为 `darwin`，使 DSH Web 呈现 macOS 风格桌面布局。
- 文档：README 更新窗口控制、热区、构建与已知限制说明。
