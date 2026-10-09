# bridge 桥接层修补前的备份（2026-10-10）

归档原因：session-4c74 于 04:35 开始给 `BridgeAgent.ets` 加窗口/剪贴板 action，未完成即中断
（当时 hvigor 编译 16 个错误）；本目录保留改动前的原始文件，供日后回溯。

| 文件 | 是什么 |
|---|---|
| `BridgeAgent.ets.bak-20261010-043555` | 加窗口 action **之后**、**编译修复之前**的中间态（即报 16 个错误的那版） |
| `module.json5.bak-screencapture-20261010` | 声明 `CUSTOM_SCREEN_CAPTURE` 之前的 module 配置 |

未删除任何内容（用户原则：冗余/退役文件不删除、归档备查）。
