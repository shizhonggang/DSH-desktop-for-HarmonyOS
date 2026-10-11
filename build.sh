#!/bin/bash
# Build the signed HAP for DshDesktop.
#
# Usage:
#   ./build.sh            # build debug (default, for device deployment)
#   ./build.sh release    # build release (for AppGallery publishing)

set -euo pipefail

export NODE_HOME="/Applications/DevEco-Studio-6.1.0.app/Contents/tools/node"
export DEVECO_SDK_HOME="/Applications/DevEco-Studio-6.1.0.app/Contents/sdk"
export DEVECO_HOME="/Applications/DevEco-Studio-6.1.0.app"
export PATH="${NODE_HOME}/bin:${PATH}"

MODE="${1:-debug}"
if [ "$MODE" != "release" ] && [ "$MODE" != "debug" ]; then
  echo "ERROR: unknown build mode '$MODE' (expected release|debug)" >&2
  exit 1
fi

cd "$(dirname "$0")"
# 构建前闸门：确认基线未落后远端（2026-10-09 事故防线，见脚本头部）
"$(dirname "$0")/scripts/prebuild-check.sh" || exit 1

node "${DEVECO_HOME}/Contents/tools/hvigor/bin/hvigorw.js" \
  --mode module \
  -p product=default \
  -p buildMode="$MODE" \
  assembleHap \
  --no-daemon
