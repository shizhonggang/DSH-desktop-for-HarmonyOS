# DSH ↔ ArkTS 桥（bridge/）

让 `dsh web`（node 侧）能够调用**只有 ArkTS 才有的系统能力**，从而把 DshDesktop 壳从"一个 WebView"升级成"dsh 的手"。

## 为什么需要它

`dsh web` 跑在本应用沙箱里，但它是个 node 进程，没有 ArkTS 运行时，因此调不到：

| 能力 | 为什么 `aa` CLI 做不到 |
|---|---|
| `startAbilityByType('navigation' \| 'mail' \| 'finance' \| 'flight' \| 'express', wantParam)` | 这是 ArkTS-only API，`aa start` 的全部开关里没有对应项（已逐项核对 `aa start -h`） |
| `startAbility(want)` 带 `flags` | `aa start` 没有 `-f/--flags`，于是跨应用读文件拿不到 `FLAG_AUTH_READ_URI_PERMISSION` |
| `openLink(url)` | 同上，CLI 无对应开关 |
| `notificationManager.publish` / `cancel`（系统通知） | `aa` 没有任何通知相关开关；WebView 里的 HTML5 Notification 在鸿蒙 Web 容器里也不可用 |
| 按别名拉起本机应用（`launchApp`） | `aa start -b X` 单独用永远失败（判为隐式匹配报 10103101），必须同时给对 ability 名 |

而这条通道**能用**：`aa start -A <action>` 已在本机实测可用（隐式 Want 能命中、错误组合返回 10104001），所以"普通隐式 Want"我们直接走 `aa`；只有上面这三类必须过桥。

## 架构

```
dsh web / dsh tools / 你的脚本
        │  POST /command {"action":…,"args":…}
        ▼
bridge/bridge-server.mjs          node 侧，127.0.0.1:3131（零依赖）
        │  GET /poll  ← 长轮询（最多挂 25s）
        ▼
BridgeAgent.ets                   ArkTS 侧，跑在 EntryAbility 里（主线程）
        │  startAbilityByType / startAbility(flags) / openLink
        ▼
系统垂类面板 / 目标应用 / 浏览器
```

实现上就是"ArkTS 主动轮询、node 被动应答"——故意这么选：
应用侧不需要监听端口（不引入 socket server API 与入站风险），而且 `http.createHttp()` 这个用法在本工程 `pages/Index.ets` 里已经在跑（健康检查），是已被验证过的路径。

## 文件

| 文件 | 作用 |
|---|---|
| `entry/src/main/ets/bridge/BridgeAgent.ets` | ArkTS 侧 agent：长轮询 + 命令分发（**需要构建进 HAP**） |
| `entry/src/main/ets/entryability/EntryAbility.ets` | 已接入：`onWindowStageCreate` 启动、`onDestroy` 停止 |
| `bridge/bridge-server.mjs` | node 侧对端：HTTP 服务 + CLI（`call` / `status` / `serve`） |
| `bridge/start-bridge.sh` | 后台起停脚本（`start` / `status` / `stop`） |
| `bridge/smoke.mjs` | 自测：用**假 agent** 跑通协议（8 项断言，不需要装 HAP） |

## 构建与安装

在 DevEco Studio 里打开本工程，签名用它的自动签名，构建并安装即可。本次改动只新增了 ArkTS 文件 + 改 `EntryAbility.ets`，**没有改 `module.json5`、没有新增权限**（回环 HTTP 走已有的 `ohos.permission.INTERNET`）。

## 使用

```sh
# 1) 起 node 侧（幂等，可反复执行）
./bridge/start-bridge.sh

# 2) 确认 agent 是否连上（connected=false 通常=壳没开或刚重启）
./bridge/start-bridge.sh status
```

### 导航（需地图类应用已接入垂类）

```sh
node bridge/bridge-server.mjs call '{"action":"startAbilityByType","args":{"type":"navigation","wantParam":{
  "sceneType":1,
  "destinationName":"上海外滩",
  "destinationLatitude":31.2340,
  "destinationLongitude":121.4910,
  "vehicleType":0}}}'
```

`sceneType`：1 路线规划、2 导航、3 位置搜索、4 地点详情；`vehicleType`：0 驾车、1 步行、2 骑行、3 公交。经纬度用 **GCJ-02**。

### 写邮件

```sh
node bridge/bridge-server.mjs call '{"action":"startAbilityByType","args":{"type":"mail","wantParam":{
  "email":["boss@example.com"],
  "cc":["me@example.com"],
  "subject":"周报",
  "body":"本周进展：…"}}}'
```

桥内部**自动做 `encodeURI`**（华为文档要求 mail 面板的 string / string[] 全部编码），所以**传明文即可，不要自己再编码一次**。

### 打开文件（带读权限授权）

```sh
node bridge/bridge-server.mjs call '{"action":"startAbility","args":{
  "action":"ohos.want.action.viewData",
  "uri":"file://com.example.dshdesktop/data/storage/el2/base/files/report.pdf",
  "type":"general.pdf",
  "flags":1,
  "parameters":{"ohos.ability.params.showDefaultPicker":true}}}'
```

`flags:1` = `FLAG_AUTH_READ_URI_PERMISSION`，`flags:2` = 写权限；`uri` 必须写成 `file://<属主bundleName>/<沙箱路径>`。

### 系统通知

```sh
# 发一条通知（点它会回到 DshDesktop 窗口）
node bridge/bridge-server.mjs call '{"action":"notify","args":{"title":"任务完成","text":"周报已生成并保存到 ~/Documents"}}'

# 长文本样式（title / text 仍必填）
node bridge/bridge-server.mjs call '{"action":"notify","args":{"title":"任务完成","text":"摘要…","longText":"完整正文…"}}'

# 复用 id 原地更新，不叠加新条（适合进度类）
node bridge/bridge-server.mjs call '{"action":"notify","args":{"id":4242,"title":"进行中","text":"3/10"}}'

# 撤掉
node bridge/bridge-server.mjs call '{"action":"dismissNotification","args":{"id":4242}}'
```

首次调用时若本应用还没有通知授权，系统会弹一次授权框（桥自动触发，并把结果如实回传）。

### 拉起本机应用（别名，零弹窗）

`bridge/apps.json` 是别名表；`launchApp` 按别名或中文名拉起，命中后走**显式 Want**（不弹任何选择框）：

```sh
node bridge/bridge-server.mjs call '{"action":"launchApp","args":{"app":"calendar"}}'
node bridge/bridge-server.mjs call '{"action":"launchApp","args":{"app":"邮件"}}'
curl -s http://127.0.0.1:3131/apps      # 列出全部别名
```

当前实测可拉起的组合（**ability 名各应用不同，必须实测**——华为系统应用里 `MainAbility` 与 `EntryAbility` 各占一半）：

| 别名 | 应用 | bundleName | abilityName |
|---|---|---|---|
| `notepad` | 备忘录 | `com.huawei.hmos.notepad` | `MainAbility` |
| `calendar` | 日历 | `com.huawei.hmos.calendar` | `MainAbility` |
| `mail` | 邮件 | `com.huawei.hmos.email` | `EntryAbility` |
| `maps` | 地图 | `com.huawei.hmos.maps.app` | `EntryAbility` |
| `finddevice` | 查找设备 | `com.huawei.hmos.finddevice` | `EntryAbility` |
| `ailife` | 智慧生活 | `com.huawei.hmos.ailife` | `EntryAbility` |

新增应用：往 `apps.json` 加一项即可，**改配置不需要重新构建 HAP**。ability 名怎么试：`aa start -b <bundle> -a <候选>`，返回 `start ability successfully.` 就是对的（`EntryAbility` / `MainAbility` 先试这两个）。

### 零弹窗：显式目标映射（targets.json）

`startAbilityByType` **每次都会弹系统垂类选择框（Intent Panel）**，这是系统设计。`bridge/targets.json` 把业务类型映射到具体应用后，node 侧会把它改写成**显式 Want**，于是不再弹框：

```json
{ "mail":       { "bundleName": "com.huawei.hmos.email",    "abilityName": "EntryAbility" },
  "navigation": { "bundleName": "com.huawei.hmos.maps.app", "abilityName": "EntryAbility" } }
```

键可以是 `type`（mail / navigation / finance / flight / express），也可以是 `type:sceneType`（如 `navigation:2`）更精确；`passParams:false` 表示不透传 `wantParam`。

**取舍要看清楚**：

| 走法 | 弹窗 | 意图参数（目的地 / 收件人…) |
|---|---|---|
| `targets.json` 命中 → 显式 Want | ❌ 无 | 只**透传**到 `parameters`，是否被目标应用解析取决于它自己 |
| 未命中 → `startAbilityByType` | ✅ 每次弹 | 由系统面板管线**保证解析** |

返回值里的 `via` 字段会告诉你走了哪条：`explicit`（零弹窗）/ `panel`（弹框）。查当前映射：`curl -s http://127.0.0.1:3131/targets`。

### 其他

```sh
# 拉起任意显式/隐式 Want（等价 aa start，但可带 flags/parameters）
node bridge/bridge-server.mjs call '{"action":"startAbility","args":{"bundleName":"com.huawei.hmos.photos","abilityName":"EntryAbility"}}'

# 用浏览器打开链接
node bridge/bridge-server.mjs call '{"action":"openLink","args":{"url":"https://developer.huawei.com"}}'

# 探活
node bridge/bridge-server.mjs call '{"action":"ping"}'
```

脚本里也可以直接打 HTTP：`POST http://127.0.0.1:3131/command`，返回 `{ok,data}` 或 `{ok:false,error}`。

## 在线查包名（可选）

没有官方"包名查询"接口。实测可用的是本机这个第三方看板（收录的是**上架 AppGallery** 的应用）：

```sh
B=https://ddns.shenjack.top:10003
# 按包名精确查
curl -sk -X POST "$B/api/v0/apps/query?page=1&page_size=5&detail=false" \
  -H 'Content-Type: application/json' -d '{"key":"pkg_name","value":"com.huawei.hmos.maps.app","op":"eq"}'
# 按名称模糊查（拿包名）
curl -sk -X POST "$B/api/v0/apps/query?page=1&page_size=10&detail=false" \
  -H 'Content-Type: application/json' -d '{"key":"name","value":"地图","op":"like"}'
# 也有 GET /api/v0/apps/pkg_name/{pkg} 与 /openapi.json（字段 70+，但不含 ability 名）
```

三点限制：① **系统内置应用不收**（如 `com.huawei.hmos.email` 查不到，得从「设置 → 应用 → 应用信息」读）；② **不含 ability 名**（任何在线源都没有，只能 `aa start` 实测）；③ 第三方服务，别当权威源。

## 自测（不需要先构建 HAP）

```sh
node bridge/smoke.mjs      # 8 passed, 0 failed = node 侧与协议正常
```

## 已知限制

1. **`startAbilityByType` 只能在主线程 + 应用在前台时调用**（系统约束）。所以壳窗口被关掉/完全后台时，这类命令会失败——返回体里会带明确原因，不是静默失败。
2. 垂类面板是**系统 UI**：多个应用接入时由**用户点选**目标应用，这是华为的设计（也是它的安全边界），不是我们能绕的。
3. 是否真的拉起，取决于目标侧是否按文档声明了 `linkFeature` / `skills`。没有接入的应用不会被面板列出。
4. 桥**只解决"拉起与传参"**，不会替你在目标应用里点按钮——那是下一阶段（无障碍）的事。

## 下一阶段（可选）：无障碍扩展 → 真正的 UI 操控

`uitest`/`snapshot_display` 这类工具被 SELinux 对本应用域整体封死（连 `stat` 都 EACCES，且盘上没有副本可洗标签），所以"读别人界面/点别人按钮"只能走**正规通道**：

在本 HAP 里加一个 `AccessibilityExtensionAbility`（`module.json5` 声明 `extensionAbilities.type = "accessibility"`），用户在「设置 → 辅助功能」里授权后，即可：
- 读当前窗口的节点树（文本 / 控件类型 / bounds）
- 按文本或坐标点击、滑动、返回键

这就是把 dsh 从"能拉起应用的启动器"变成"能操作应用的 agent"的那一步。它需要额外的构建 + 一次手动授权，因此单独作为第二阶段，等第一阶段在你的设备上跑通后再加。

## 排障

| 现象 | 原因 |
|---|---|
| `bridge server unreachable` | node 侧没起：`./bridge/start-bridge.sh` |
| `agent.connected: false` | 壳没开，或壳是在桥之前启动的（重启壳即可；agent 会自动重连） |
| `timeout` | 壳在后台 / 命令需要前台；或目标应用未接入垂类 |
| `startAbilityByType failed, code=16000050` | 系统内部错误，多半是没有匹配的垂类应用 |
| 邮件参数出现 `%E4%B8%AD` 字样 | 你重复编码了：传明文，桥自己编码 |
