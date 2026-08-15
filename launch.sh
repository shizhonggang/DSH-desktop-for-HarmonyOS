#!/bin/bash
# Launch helper for DshDesktop on HarmonyOS/OpenHarmony 2in1 devices.
#
# This script runs on your macOS host. It:
#   1. Starts "dsh web" on the host (if not already running).
#   2. Forwards device localhost:3080 -> host localhost:3080 via hdc.
#   3. Installs the signed HAP.
#   4. Launches the app.
#
# The HAP cannot auto-start dsh by itself because OpenHarmony user apps are
# sandboxed and cannot spawn arbitrary shell processes. Use this script during
# development instead.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
HAP_PATH="${PROJECT_DIR}/entry/build/default/outputs/default/entry-default-signed.hap"
HOST_PORT=3080
DEVICE_PORT=3080
BUNDLE_NAME="com.example.dshdesktop"
ABILITY_NAME="${BUNDLE_NAME}.EntryAbility"

# --- locate hdc ---
if command -v hdc >/dev/null 2>&1; then
  HDC=hdc
elif [ -x "/Applications/DevEco-Studio-26.0.0.app/Contents/sdk/default/openharmony/toolchains/hdc" ]; then
  HDC="/Applications/DevEco-Studio-26.0.0.app/Contents/sdk/default/openharmony/toolchains/hdc"
else
  echo "ERROR: hdc not found. Add it to PATH or update DEVECO_SDK_HOME." >&2
  exit 1
fi

# --- ensure a device is connected ---
if ! "$HDC" list targets 2>/dev/null | grep -q "^[0-9]"; then
  echo "ERROR: no HarmonyOS device/emulator connected via hdc." >&2
  exit 1
fi

# --- start dsh web on the host if needed ---
DSH_PID=""
if curl -s --max-time 2 "http://127.0.0.1:${HOST_PORT}/" >/dev/null 2>&1; then
  echo "[dsh] already running on http://127.0.0.1:${HOST_PORT}"
else
  echo "[dsh] starting dsh web --host 127.0.0.1 --port ${HOST_PORT}"
  dsh web --host 127.0.0.1 --port "${HOST_PORT}" >/tmp/dsh-web.log 2>&1 &
  DSH_PID=$!
  # wait up to 10s for the server to be ready
  for i in $(seq 1 20); do
    if curl -s --max-time 1 "http://127.0.0.1:${HOST_PORT}/" >/dev/null 2>&1; then
      echo "[dsh] ready"
      break
    fi
    sleep 0.5
  done
  if ! curl -s --max-time 2 "http://127.0.0.1:${HOST_PORT}/" >/dev/null 2>&1; then
    echo "ERROR: dsh web failed to start. Check /tmp/dsh-web.log" >&2
    [ -n "$DSH_PID" ] && kill "$DSH_PID" 2>/dev/null || true
    exit 1
  fi
fi

# --- forward device:3080 -> host:3080 ---
echo "[hdc] forwarding device ${DEVICE_PORT} -> host ${HOST_PORT}"
"$HDC" fport tcp:"${DEVICE_PORT}" tcp:"${HOST_PORT}" || {
  echo "WARN: port forward failed (maybe already forwarded). Continuing..."
}

# --- install HAP ---
if [ ! -f "$HAP_PATH" ]; then
  echo "ERROR: HAP not found at ${HAP_PATH}. Build it first with: ./build.sh" >&2
  [ -n "$DSH_PID" ] && kill "$DSH_PID" 2>/dev/null || true
  exit 1
fi

echo "[hdc] installing ${HAP_PATH}"
"$HDC" install "$HAP_PATH"

# --- launch app ---
echo "[hdc] launching ${BUNDLE_NAME}/${ABILITY_NAME}"
"$HDC" shell am start -n "${BUNDLE_NAME}/${ABILITY_NAME}"

echo "[done] DshDesktop launched. dsh web logs: /tmp/dsh-web.log"
[ -n "$DSH_PID" ] && echo "[info] dsh web PID: ${DSH_PID}"
