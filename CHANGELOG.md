# Changelog

本仓库所有值得记录的变更。格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，
版本遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [未发布]

### 修复

- **兼容 dsh web 的 token 认证**：dsh web 每次启动生成随机 token，WebView 裸连会被
  401 拒绝。
  - `EntryAbility` 支持读取启动参数 `dsh_token` 并存入 AppStorage；
  - `Index.ets` 首次加载带 `?token=…` 完成一次性认证握手（换取 30 天有效 cookie），
    之后免 token 直连；
  - 新增 `launch-local.sh`：鸿蒙本机启动辅助，自动解析 dsh web 输出中的 token 并传给应用；
  - 新增 `scripts/dsh-client-connection-loopback.patch`：给 dsh web 打本地回环免认证
    补丁后，本应用可完全免 token 接入（首页与 `/api` 均放行），见 README。
- 文档：README 新增「与 dsh web 的连接与认证」说明。

