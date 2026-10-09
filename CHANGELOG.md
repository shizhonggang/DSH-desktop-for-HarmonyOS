# Changelog

本仓库所有值得记录的变更。格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，
版本遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [未发布]

### 新增

- **DSH ↔ ArkTS 桥**：让 `dsh web`（node 侧）能调用只有 ArkTS 才有的系统能力，补齐
  `aa` CLI 覆盖不到的四类调用：

  | 能力 | `aa start` | 本桥 |
  |---|---|---|
  | 普通隐式 Want | ✅ | ✅ |
  | `startAbilityByType`（导航/邮件/金融/航班/快递垂类面板） | ❌ 无对应开关 | ✅ |
  | `startAbility` 带 `flags`（如文件读权限授权） | ❌ 无 `-f` | ✅ |
  | `openLink` | ❌ | ✅ |
  | 系统通知 `notify` / `dismissNotification` | ❌ 无任何通知开关 | ✅ |

  - 新增 `entry/src/main/ets/bridge/BridgeAgent.ets`：ArkTS 侧 agent，长轮询 node 侧
    回环端点并执行命令；按华为文档对 mail 面板的参数自动 `encodeURI`（navigation
    保持明文），调用方一律传明文。
  - `EntryAbility` 在 `onWindowStageCreate` 启动 / `onDestroy` 停止该 agent。
  - 新增 `bridge/bridge-server.mjs`：node 侧对端（零依赖），提供
    `/poll`、`/result`、`/command`、`/healthz` 与 `call` / `status` CLI。
  - 新增 `bridge/start-bridge.sh`（后台起停）与 `bridge/smoke.mjs`（假 agent 协议自测，
    8 项断言，无需先装 HAP）。
  - 新增 `bridge/README.md`：架构、构建、用法示例、限制与下一阶段（无障碍扩展）说明。
  - 通知：`notify` / `dismissNotification` 两个动作，支持基础文本与长文本两种样式、
    复用 id 原地更新（进度类）、点击通知回到 DshDesktop 窗口；首次调用若未授权会由桥
    自动触发系统授权框并把结果如实回传（`ensureNotificationsEnabled`）。
  - 新增 `bridge/apps.json` + `launchApp` 动作：按别名/中文名拉起本机应用，走显式 Want
    零弹窗；已实测 6 个（备忘录/日历/邮件/地图/查找设备/智慧生活）。
  - 新增 `bridge/targets.json`：把 `startAbilityByType` 的业务类型映射到具体应用，命中即改写为
    显式 Want → 不再弹系统垂类选择框；返回值新增 `via`（explicit/panel）与 `target` 字段；
    新增 `GET /apps` 与 `GET /targets`。改动均在 node 侧，**不需要重新构建 HAP**。
  - 修：`bridge/start-bridge.sh` 的 `stop` 原先用 `pkill -f bridge-server.mjs`，会误杀 cmdline 里
    含该字符串的任意进程（含正在执行它的 shell）——改为仅按 pidfile 停止。
  - 经验记录：华为系统应用的入口 ability 名不统一，`MainAbility` 与 `EntryAbility` 各占一半，
    只能靠 `aa start -b <bundle> -a <候选>` 实测（返回 `start ability successfully.` 即命中）。
  - **第二阶段：无障碍扩展**（`entry/src/main/ets/accessibility/`）：`DshAccessibilityAbility`
    + 独立的 `AccessibilityBridgeAgent`（轮询 `?channel=a11y`）。动作：`a11yWindows` /
    `a11yFocus` / `a11yFind` / `a11yClick` / `a11yTap` / `a11ySwipe` / `a11yLastEvent`。
    node 侧改为**双通道**（按动作名前缀 `a11y*` 分流），`healthz` 分别报告。
    需要用户在「设置 → 辅助功能」手动开启；`module.json5` 新增 `type: "accessibility"`
    扩展声明 + `resources/base/profile/accessibility_config.json`。
  - 未新增任何权限：回环 HTTP 走已有的
    `ohos.permission.INTERNET`。

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
