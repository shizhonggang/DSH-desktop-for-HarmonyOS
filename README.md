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
│   ├─ JS Bridge (dshNative): 最小化/关闭/缩放/主题/最大化/侧边栏状态 │
│   ├─ 快捷键 / 右键菜单 / session-log 按钮隐藏     │
│   └─ dsh web 未启动时的错误页                   │
└──────────────┬───────────────────────────────┘
               │ http://127.0.0.1:3080/?dsh-desktop-platform=darwin
┌──────────────▼───────────────────────────────┐
│ 系统侧 `dsh web`（Host，需单独启动）            │
└──────────────────────────────────────────────┘
```

HAP 是纯 Web 客户端；Host（`dsh web`）跑在系统侧，与 Electron 版共用同一套前端。

## 功能

- 无标题栏（`setWindowDecorVisible(false)` + `setWindowTitleButtonVisible(false,false,false)`），左上角自绘 macOS 风格红/黄/绿窗口控制按钮
- hover 时显示 `×` / `−` / 绿色系统 SymbolGlyph；左侧侧边栏收起时按钮同步隐藏
- 顶部拖拽热区高度 28vp，右侧排除 220vp；双击热区使用 `window.maximize()` / `window.recover()` 最大化/还原
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

- DevEco Studio 6.1.0.860（含 HarmonyOS SDK 6.1.0（API 23，version 6.1.0.105）/ hvigor 6.23.7）
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

## 与 dsh web 的连接与认证（token）

dsh web 每次启动会生成一个随机的进程 token；浏览器需带 `?token=…` 访问一次，
由 dsh web 签发一个绑定 `127.0.0.1:3080` 的持久签名 cookie，之后 30 天内免 token。
本应用是 WebView（沙箱内不能跑 shell 去解析 dsh web 打印的 token），因此支持两种接入方式：

**方式一（推荐）：给 dsh web 打「本地回环免认证」补丁**

补丁文件：`scripts/dsh-client-connection-loopback.patch`（本仓库随附）

```sh
cd "$(npm root -g)/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-client-connection"
git apply ~/path/to/scripts/dsh-client-connection-loopback.patch   # 或手工按文件注释加
```

补丁让 loopback（`127.0.0.1`）来源的**首页与 `/api` 请求都免 token/cookie**——
本应用裸连 `http://127.0.0.1:3080/?dsh-desktop-platform=darwin` 即可直接进入，
目录选择 / 权限 / 会话全部可用，且与浏览器 GUI 共用同一实例、内容全同步。
> 注意：升级或重装 dsh 后需重打此补丁。

**方式二（免补丁）：启动时传入 token，首次握手种 cookie**

本应用 `EntryAbility` 会读取启动参数 `dsh_token`；`Index.ets` 拿到后首次加载带
`?token=…` 完成一次性认证（自动换持久 cookie），之后免 token。启动辅助见
`launch-local.sh`（解析 dsh web 输出中的 token 并 `aa start` 传入），也可手动：

```sh
aa start -b com.example.dshdesktop -a EntryAbility --es dsh_token <从 dsh web 输出复制的 token>
```

> 无论哪种方式，都建议让 dsh web 以**单一实例**占用 `3080`，浏览器 GUI 与应用共用，
> 会话 / 工作区 / 权限实时一致。

## 已知限制

- OpenHarmony 用户应用无法自动拉起系统侧的 `dsh web`（沙箱限制），需手动 / 由系统脚本启动。
- 自绘窗口控件依赖 WebView JS 注入与 DSH DOM 结构；DSH Web 升级后侧边栏折叠检测可能需要适配。
- HarmonyOS 部分设备/版本可能仍显示原生标题按钮；此时左上角自绘按钮仍可使用，但会出现两套按钮。
- 文件拖拽依赖目标设备 WebView 对 HTML5 `drop` 事件的支持，应用侧已开启窗口接收拖拽事件。
- 插件生态：纯前端插件可用；依赖 Electron/Node 主进程 API 的插件需额外适配。

## License

Apache License 2.0（见各源文件头部声明）。DeepSeek Harness 及其图标版权归原项目所有。
