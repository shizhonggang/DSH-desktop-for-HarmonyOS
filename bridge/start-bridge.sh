#!/bin/sh
# Start (or stop / check) the DSH <-> ArkTS bridge server.
#
#   ./start-bridge.sh          start in the background (idempotent)
#   ./start-bridge.sh status   print /healthz
#   ./start-bridge.sh stop     stop the background server
#
# The ArkTS half lives inside the DshDesktop HAP; it only answers while the
# DshDesktop window exists, so `status` reporting agent.connected=false just
# means the app is closed (or was launched before the server started).
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
PORT="${DSH_BRIDGE_PORT:-3131}"
URL="http://127.0.0.1:$PORT"
LOG="${DSH_BRIDGE_LOG:-$DIR/bridge.log}"
PIDFILE="$DIR/bridge.pid"
NODE_BIN="${DSH_BRIDGE_NODE:-node}"

alive() {
  curl -s --max-time 2 "$URL/healthz" >/dev/null 2>&1
}

case "${1:-start}" in
  status)
    if alive; then curl -s "$URL/healthz"; echo; else echo "[bridge] not running on port $PORT"; exit 1; fi
    ;;
  stop)
    if [ -f "$PIDFILE" ]; then
      kill "$(cat "$PIDFILE")" 2>/dev/null && echo "[bridge] stopped (pid $(cat "$PIDFILE"))" || echo "[bridge] pid $(cat "$PIDFILE") was not running"
      rm -f "$PIDFILE"
    else
      echo "[bridge] no pidfile"
    fi
    ;;
  start|*)
    if alive; then
      echo "[bridge] already running on port $PORT"
      curl -s "$URL/healthz"; echo
      exit 0
    fi
    nohup "$NODE_BIN" "$DIR/bridge-server.mjs" >>"$LOG" 2>&1 &
    echo $! > "$PIDFILE"
    i=0
    while [ "$i" -lt 20 ]; do
      if alive; then
        echo "[bridge] started on port $PORT (pid $(cat "$PIDFILE")); log: $LOG"
        curl -s "$URL/healthz"; echo
        exit 0
      fi
      i=$((i + 1))
      sleep 0.25
    done
    echo "[bridge] failed to start — see $LOG" >&2
    exit 1
    ;;
esac
