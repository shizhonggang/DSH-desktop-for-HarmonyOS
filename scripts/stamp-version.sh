#!/bin/sh
# stamp-version.sh — 把当前 commit 盖进 AppScope/app.json5，让"装的是哪份代码"可自证。
#
#   versionCode = 1000000 + commit 数     （随提交单调递增）
#   versionName = <x.y.z>+<shortsha>      （安装后可在「设置 → 应用信息」看到）
#
# 为什么需要：DevEco Studio 的 GUI 构建会绕过 build.sh 的 prebuild-check.sh 闸门，
# 所以"基线是否正确"最终要靠**产物自证**——装完看一眼版本号就知道是哪个 commit。
#
# ⚠ versionName 里的 `+sha` 仅供本地/调试构建；准备上架 AppGallery 前请去掉（重新
#   运行一次并手动改回纯 x.y.z，或发版前 revert 本文件的改动）。
#
# 用法： scripts/stamp-version.sh        # 盖章（幂等，可反复跑）
set -eu

cd "$(dirname "$0")/.." || exit 1

python3 - <<'PY'
import re, subprocess, sys

path = "AppScope/app.json5"
src = open(path, encoding="utf-8").read()

sha = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], text=True).strip()
count = subprocess.check_output(["git", "rev-list", "--count", "HEAD"], text=True).strip()
dirty = subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True).stdout.strip()
suffix = "+" + sha + (".dirty" if dirty else "")

m = re.search(r'"versionName"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)', src)
if not m:
    print("找不到 versionName（期望形如 1.2.0）", file=sys.stderr)
    sys.exit(1)
base = m.group(1)

code = 1000000 + int(count)
new = re.sub(r'("versionCode"\s*:\s*)\d+', lambda x: x.group(1) + str(code), src, count=1)
new = re.sub(r'("versionName"\s*:\s*")[^"]*(")',
             lambda x: x.group(1) + base + suffix + x.group(2), new, count=1)
open(path, "w", encoding="utf-8").write(new)
print(f"[stamp] versionCode={code}  versionName={base}{suffix}")
PY

git --no-pager diff --stat AppScope/app.json5 | sed 's/^/[stamp] /'
