#!/bin/sh
# prebuild-check.sh — 构建前闸门：确保你构建的代码基线与 GitHub 一致。
#
# 为什么需要它：`git status` 比对的是**本地缓存的** origin/* 引用，只有 `git fetch`
# 才会更新。所以"看起来领先 N 个提交"有时候真相是"落后 N 个提交"，照着构建就会用旧
# 代码顶掉新版功能（2026-10-09 的 🚥 窗口管理就是这么丢的）。
#
# 用法：
#   scripts/prebuild-check.sh            # 落后远端 → 退出码 1；有未提交改动 → 仅警告
#   scripts/prebuild-check.sh --strict   # 有未提交改动也退出码 1（工作区必须可对应某个提交）
#
# 退出码：0 可以构建；1 不要构建。
set -u

STRICT=0
[ "${1:-}" = "--strict" ] && STRICT=1

cd "$(dirname "$0")/.." || exit 1

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
HEAD=$(git rev-parse --short HEAD 2>/dev/null || echo "?")
UPSTREAM="origin/$BRANCH"

echo "[prebuild] 分支 $BRANCH @ $HEAD"

# --- 1) 工作区状态 ---------------------------------------------------------
DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
if [ "$DIRTY" -ne 0 ]; then
  echo "[prebuild] ⚠ 工作区有 $DIRTY 项未提交改动 —— 这个构建产物无法对应任何 commit"
  if [ "$STRICT" -eq 1 ]; then
    echo "[prebuild] ❌ --strict：请先提交或 git stash -u"
    git status --short | sed 's/^/[prebuild]      /'
    exit 1
  fi
fi

# --- 2) 与远端一致性（网络失败只警告，不阻断离线构建）---------------------
if git fetch --quiet --tags origin 2>/dev/null; then
  BEHIND=$(git rev-list --count "$HEAD..$UPSTREAM" 2>/dev/null || echo 0)
  AHEAD=$(git rev-list --count "$UPSTREAM..$HEAD" 2>/dev/null || echo 0)
  echo "[prebuild] 与 $UPSTREAM 相比：落后 $BEHIND，领先 $AHEAD"
  if [ "$BEHIND" -gt 0 ]; then
    echo "[prebuild] ❌ 本地落后远端 $BEHIND 个提交 —— 直接构建会顶掉新版功能："
    git log --oneline "$HEAD..$UPSTREAM" | sed 's/^/[prebuild]      /'
    echo "[prebuild]    处理： git stash -u && git merge --ff-only $UPSTREAM && git stash pop"
    exit 1
  fi
else
  echo "[prebuild] ⚠ 无法 fetch（离线？）—— 跳过远端一致性检查，无法确认基线是否最新"
fi

echo "[prebuild] ✅ 基线检查通过：$BRANCH @ $HEAD"
