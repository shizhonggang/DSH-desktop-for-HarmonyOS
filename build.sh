#!/bin/bash
# Build the signed HAP for DshDesktop.
#
# Usage:
#   ./build.sh            # build release (default, for publishing)
#   ./build.sh debug      # build debug

set -euo pipefail

export NODE_HOME="/Applications/DevEco-Studio-26.0.0.app/Contents/tools/node"
export DEVECO_SDK_HOME="/Applications/DevEco-Studio-26.0.0.app/Contents/sdk"
export DEVECO_HOME="/Applications/DevEco-Studio-26.0.0.app"
export PATH="${NODE_HOME}/bin:${PATH}"

MODE="${1:-release}"
if [ "$MODE" != "release" ] && [ "$MODE" != "debug" ]; then
  echo "ERROR: unknown build mode '$MODE' (expected release|debug)" >&2
  exit 1
fi

cd "$(dirname "$0")"
node "${DEVECO_HOME}/Contents/tools/hvigor/bin/hvigorw.js" \
  --mode module \
  -p product=default \
  -p buildMode="$MODE" \
  assembleHap \
  --no-daemon
