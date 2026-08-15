# DSH-desktop-for-HarmonyOS

[DeepSeek Harness](https://github.com/anywhere-labs/deepseek-harness-desktop) 桌面端移植到
HarmonyOS / OpenHarmony 2in1（PC）设备的客户端。图标使用 DSH 黑鲸默认图标。

> 这是**客户端壳（WebView 容器）**。业务 UI 由系统侧的 `dsh web` Host 提供，本应用加载
> `http://127.0.0.1:3080` 呈现 DeepSeek Harness 的浏览器界面。

## 架构

```
┌──────────────────────────────────────────────┐
│ HarmonyOS HAP (本仓库)                        │
│  ArkUI 窗口 + Web 组件                        │
│   ├─ 窗口装饰隐藏 / 深浅色 / 窗口状态持久化      │
│   ├─ JS Bridge (dshNative): 最小化/关闭/缩放/主题 │
│   ├─ 快捷键 / 右键菜单 / session-log 按钮隐藏     │
│   └─ dsh web 未启动时的错误页                   │
└──────────────┬───────────────────────────────┘
               │ http://127.0.0.1:3080/?dsh-desktop-platform=linux
┌──────────────▼───────────────────────────────┐
│ 系统侧 `dsh web`（Host，需单独启动）            │
└──────────────────────────────────────────────┘
```

HAP 是纯 Web 客户端；Host（`dsh web`）跑在系统侧，与 Electron 版共用同一套前端。

## 功能

- 无标题栏（`setWindowDecorVisible(false)`），窗口管理按钮仍在系统右上角
- 隐藏 dsh web 的 session-log 按钮，避免与系统窗口按钮重叠
- 跟随系统深浅色，支持手动循环切换并持久化
- 窗口大小 / 位置持久化（`preferences`）
- dsh web 未启动时的中文错误页 + 重试
- JS Bridge：网页可通过 `window.dshNative` 控制窗口与缩放
- 桌面快捷键（注入到网页）
- 自定义右键菜单
- 后台通知（相当于托盘，点击可重新唤起）

### 快捷键

| 快捷键 | 作用 |
| --- | --- |
| `Ctrl/Cmd + W` | 隐藏 / 最小化窗口 |
| `Ctrl/Cmd + R` | 刷新页面 |
| `Ctrl/Cmd + +/-` | 放大 / 缩小 |
| `Ctrl/Cmd + 0` | 重置缩放 |
| `Ctrl/Cmd + Shift + L` | 循环切换 跟随系统 / 浅色 / 深色 |

## 环境要求

- DevEco Studio 26.0.0.461（含 HarmonyOS SDK 26.0.0（Beta1，version 26.0.0.23）/ hvigor 6.26.1）
- HarmonyOS / OpenHarmony `2in1` 设备或模拟器
- 系统侧已安装并可运行 `dsh web`（Node.js）

## 构建

```bash
./build.sh            # release（默认）
./build.sh debug      # debug
```

输出：`entry/build/default/outputs/default/entry-default-signed.hap`

> **签名**：本仓库的 `build-profile.json5` 不含任何签名配置。首次构建前，在
> DevEco Studio 中配置签名（`File > Project Structure > Signing Configs`），或手动在
> `build-profile.json5` 的 `signingConfigs` 中填入你自己的证书。**切勿把签名密码提交到仓库。**

## 运行

`dsh web` 需先运行在目标设备的 `127.0.0.1:3080`（或用 `hdc` 转发）。macOS 开发时可用：

```bash
./launch.sh   # 启动 dsh web + hdc 端口转发 + 安装 + 启动应用
```

## 已知限制

- OpenHarmony 用户应用无法自动拉起系统侧的 `dsh web`（沙箱限制），需手动 / 由系统脚本启动。
- 系统窗口按钮（关闭/最小化/最大化）在部分设备上无法隐藏，应用以隐藏 session-log 按钮避让。
- 文件拖拽依赖目标设备 WebView 对 HTML5 `drop` 事件的支持，应用侧已开启窗口接收拖拽事件。
- 插件生态：纯前端插件可用；依赖 Electron/Node 主进程 API 的插件需额外适配。

## License

Apache License 2.0（见各源文件头部声明）。DeepSeek Harness 及其图标版权归原项目所有。
