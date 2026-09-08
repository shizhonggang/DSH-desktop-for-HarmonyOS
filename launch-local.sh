#!/bin/sh
# launch-local.sh — 鸿蒙本机版 DshDesktop 启动器
# ---------------------------------------------------------------------------
# 目的：解决 dsh web 的 token 认证。dsh web 每次启动生成随机 token，WebView
#       不带 token 访问会 401。本脚本：
#         1) 确保本机 dsh web 在 127.0.0.1:3080 运行（没有则启动）
#         2) 从 dsh web 输出里解析本次的 token
#         3) 用 `aa start --es dsh_token <token>` 启动 HAP，让 WebView 首次
#            加载 `/?token=…` 完成一次性握手（dsh web 会回 303 并种下持久
#            签名 cookie），之后 HAP 内免 token 直接可用。
#
# 用法：bash launch-local.sh
# 依赖：dsh web（~/.local/bin/dsh-web 或 dsh 命令）、aa（本机）、已装 HAP
# ---------------------------------------------------------------------------
set -u

# dsh web 地址与端口（与 Index.ets 的 DSH_WEB_URL 保持一致）
DSH_URL="http://127.0.0.1:3080"
DSH_LOG="${DSH_HOME:-$HOME/.dsh}/dsh-web-local.log"
BUNDLE_NAME="com.example.dshdesktop"
ABILITY_NAME="EntryAbility"

# 1) 确保 dsh web 在跑
if curl -s --max-time 2 "$DSH_URL/" >/dev/null 2>&1; then
  echo "[dsh] 已在运行: $DSH_URL"
else
  echo "[dsh] 启动 dsh web ..."
  # 优先用鸿蒙专用包装脚本（带 --expose-internals），否则退回 dsh 命令
  if [ -x "$HOME/.local/bin/dsh-web" ]; then
    "$HOME/.local/bin/dsh-web" >"$DSH_LOG" 2>&1 &
  elif command -v dsh >/dev/null 2>&1; then
    dsh web --host 127.0.0.1 --port 3080 >"$DSH_LOG" 2>&1 &
  else
    echo "ERROR: 找不到 dsh web（需要 ~/.local/bin/dsh-web 或 dsh 命令）" >&2
    exit 1
  fi
  # 等就绪（最多 20 秒）
  for i in $(seq 1 40); do
    if curl -s --max-time 1 "$DSH_URL/" >/dev/null 2>&1; then break; fi
    sleep 0.5
  done
  if ! curl -s --max-time 2 "$DSH_URL/" >/dev/null 2>&1; then
    echo "ERROR: dsh web 启动失败，看日志: $DSH_LOG" >&2
    exit 1
  fi
  echo "[dsh] dsh web 已就绪（日志: $DSH_LOG）"
fi

# 2) 解析本次 token：dsh web 会在输出里打印含 token 的 URL
#    「dsh web: http://127.0.0.1:3080/?token=xxxxx」
TOKEN=""
if [ -f "$DSH_LOG" ]; then
  TOKEN=$(grep -o 'token=[A-Za-z0-9_-]*' "$DSH_LOG" 2>/dev/null | head -1 | cut -d= -f2)
fi
if [ -z "$TOKEN" ]; then
  echo "[warn] 未能从日志解析 token（日志文件尚新？）。将尝试不带 token 启动，"
  echo "       若 HAP 内仍 401，请手动带 token 访问一次 $DSH_URL/?token=… 种 cookie。"
fi

# 3) 启动 HAP（把 token 作为 want parameter 传给 EntryAbility）
if [ -n "$TOKEN" ]; then
  echo "[aa] 启动 $BUNDLE_NAME/$ABILITY_NAME（携带 dsh_token）"
  aa start -b "$BUNDLE_NAME" -a "$ABILITY_NAME" --es dsh_token "$TOKEN" 2>&1 || {
    echo "WARN: aa 带 --es 参数失败，退回不带 token 启动（可手工种 cookie）"
    aa start -b "$BUNDLE_NAME" -a "$ABILITY_NAME"
  }
else
  echo "[aa] 启动 $BUNDLE_NAME/$ABILITY_NAME（无 token）"
  aa start -b "$BUNDLE_NAME" -a "$ABILITY_NAME"
fi

echo "[done] DshDesktop 启动。dsh web 日志: $DSH_LOG"
