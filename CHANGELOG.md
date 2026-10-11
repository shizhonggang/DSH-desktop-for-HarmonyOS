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
  - **实测边界（2026-10-09）**：第三方无障碍扩展在本机**无法启用**——扩展已正确注册
    （bm dump 可见 accessibility 类型），但「设置 → 辅助功能」页只有系统自身的视觉/听觉选项，
    **不存在「已安装的服务」入口**（uitest dumpLayout 逐节点核对）。与华为不放第三方无障碍
    服务开发指南一致 → 该能力保留给系统应用。a11y 代码保留但当前不可用。
  - **可用的 UI 操控通道**：`hdc → sh 域(uid 2000) → uitest`。hdc 取自 hmos-clt
    （`/data/service/hnp/hmos-clt.org/hmos-clt_1.0.0/sdk/default/openharmony/toolchains/hdc`），
    目标 `127.0.0.1:34413`。已实测：dumpLayout 读界面树、screenCap 截图、uiInput click 点击、
    bm dump -a 列全部应用。详见 bridge/README.md。
  - 未新增任何权限：回环 HTTP 走已有的
    `ohos.permission.INTERNET`。

### 新增（2026-10-11）

- **桥接层 10 → 21 动作**：新增窗口感知（`listMainWindows` / `getWindowLayouts`）、
  窗口截图（`snapshotWindow` + `fetchFile` 取回字节）、自身窗口控制（`getSelfWindowInfo` /
  `moveSelfWindow` / `resizeSelfWindow` / `setSelfWindowMode`）、`listDisplays`、
  `requestScreenCapture`、应用内 OCR（`ocrImage`，Core Vision Kit）等。
- **服务卡片修复与打通**：三卡片统一 `@State` + 抽取 `CardShared`（修复宽卡/迷你卡空白）、
  大卡片任务列表改 `@Watch + @State`；桥 `updateCard` 广播路径改用零权限
  `formProvider.getFormsInfo()`（原 `getPublishedRunningFormInfos()` 三方不可用，报 16500100），
  宿主侧推送后桌面卡片实时刷新。
- **自绘窗口描边**：窗口态下根层叠加 2vp 描边（圆角 16vp 与系统窗角实测对齐，
  浅色 `rgba(0,0,0,0.25)` / 深色 `rgba(255,255,255,0.24)`），最大化/全屏自动隐藏；
  最大化状态统一以 `window.getWindowStatus()` + `windowStatusDidChange` 事件为准。
- **主题色衬底**：根 Stack 铺与 Web 主题同色的衬底（深 `#232426` / 浅 `#FFFFFF`），
  掩盖 ArkWeb 窗口缩放时的异步重绘空白。
- **JS 桥安全加固**：`javaScriptProxy` 增加 URL 白名单，`dshNative` 仅允许
  `http://127.0.0.1:3080` 调用（官方 `javascriptProxyPermission` schema）。
- **长时任务常驻**：`MODE_TASK_KEEPING` 连续任务（PC/2in1 免 ACL），关窗/后台后应用进程与
  ArkTS 桥常驻，结果经桥 `sendEvent('continuousTask')` 回传 node 侧日志；
  `launch-local.sh` 启动 HAP 前幂等确保 bridge-server 在跑。
- **图标**：logo 反色为白鲸黑底、主体放大到 70%，并按墨迹质心居中修正视觉重心。

### 修复（2026-10-11）

- **绿灯/拖拽热区偶发失效**：最大化判定从本地标志位改为 `getWindowStatus()`（标志位会被
  系统手势/双击脱同步）；最大化态下拖拽热区先 `recover()`（WMS 拒绝在最大化时 moveWindowTo）。
- **描边撞色隐形**：系统深色 + 应用内浅色（或反之）时描边与窗口同色看似消失——
  dark 资源限定符跟随系统模式而非应用覆盖，改为按应用有效颜色模式代码内计算
  （`mediaquery` 监听系统档）。
- **签名材料出仓**：`build-profile.json5` 的 `signingConfigs` 清空（含加密口令与本地证书
  路径），证书/私钥/profile 统一放已被忽略的 `key/` 目录，本机构建见 README「签名」节。

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
