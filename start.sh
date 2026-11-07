#!/bin/bash
# start-resolve-ai.sh
# Starts Splash (Qwen Flash-Next IQ3_S) + dashboard + DaVinci Resolve + Claude Code
# Optional fallback: --27b
#
# Memory sizing was measured on an M5 Ultra 96 GB with Resolve Studio running
# concurrently (2026-10/11 iteration log preserved below — tune via env vars
# rather than editing):
#   MAX_MEMORY=56G  — leaves ~40 GB of slack for Resolve + macOS on 96 GB while
#                     keeping the KV pool ~10 GB (~770k tokens, 3x the 262k ctx).
#                     Smaller machines: try 24–32 GB; the engine prints its own
#                     recommended working set at startup.
#   MAX_CACHE_DISK=128G — the 64 G prefix cache saturated and started evicting
#                     warm prefixes; disk cache is cheap, RAM is not.
#   --expert-memory auto — splash >= 1.6.0 elastic expert store; a fixed size
#                     disables elasticity. Keep 'auto'.
#   THINKING_BUDGET=16384 — caps runaway deliberation so requests still answer.
#
# One-off overrides without editing:
#   MAX_MEMORY=32G MAX_CACHE_DISK=64G ./start-resolve-ai.sh

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────
MODEL_FLASH="ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:IQ3_S"
MODEL_27B="unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M"   # adjust if you use a different quant

SPLASH_PORT=8000
DASH_PORT=8280

MAX_CACHE_DISK="${MAX_CACHE_DISK:-128G}"
PERSISTENT_CACHE=1
MAX_MEMORY="${MAX_MEMORY:-56G}"
REASONING_EFFORT="xhigh"    # only for requests that set none (the Chat UI); Claude Code sets its own
THINKING_BUDGET="16384"     # cap runaway thinking so requests still answer (~3 min worst case)

# Optional: put the persistent cache on an external SSD
# Example: EXTERNAL_CACHE="/Volumes/YourExternalSSD/splash-cache"
EXTERNAL_CACHE=""

OPEN_MACMON=1               # pop a second Terminal window running the macmon TUI
OPEN_METRICS=1              # brew services leg: Prometheus (:9090) scrapes the engine's
                            # /metrics; Grafana (:3000) serves "Splash Engine Overview"
                            # with history the live dashboard can't keep. --no-metrics skips it.

# Engine logs live where dash.py's log stream tails them:
LOG_DIR="${HOME}/Library/Logs/splash"
LOG_OUT="${LOG_DIR}/splash.out.log"
LOG_ERR="${LOG_DIR}/splash.err.log"
mkdir -p "$LOG_DIR"
[[ -L "$LOG_OUT" ]] && rm -f "$LOG_OUT"

DASH_DIR="${HOME}/splash-dashboard"
DASH_PID_FILE="${HOME}/.splash-dashboard.pid"
SPLASH_PID_FILE="${HOME}/.splash.pid"

# ── Parse flags ────────────────────────────────────────────────────
MODEL="$MODEL_FLASH"
for arg in "$@"; do
  case "$arg" in
    --27b) MODEL="$MODEL_27B" ;;
    --no-macmon) OPEN_MACMON=0 ;;
    --no-metrics) OPEN_METRICS=0 ;;
    -h|--help)
      echo "Usage: $0 [--27b] [--no-macmon] [--no-metrics]"
      echo "  Env overrides: MAX_MEMORY=56G MAX_CACHE_DISK=128G EXTERNAL_CACHE=/path"
      exit 0 ;;
    *) echo "Unknown argument: $arg (try --help)" >&2; exit 1 ;;
  esac
done

info()  { echo "→ $*"; }
warn()  { echo "⚠ $*"; }
error() { echo "✗ $*" >&2; exit 1; }

kill_pidfile() {
  local pidfile="$1" label="${2:-process}"
  if [[ -f "$pidfile" ]]; then
    local old; old=$(cat "$pidfile" 2>/dev/null || true)
    if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
      info "Stopping previous $label (pid $old)..."
      kill "$old" 2>/dev/null || true
      for _ in 1 2 3; do kill -0 "$old" 2>/dev/null || break; sleep 0.4; done
      if kill -0 "$old" 2>/dev/null; then warn "Force-killing $label"; kill -9 "$old" 2>/dev/null || true; fi
    fi
    rm -f "$pidfile"
  fi
}

tail_logs_on_failure() {
  echo "── last 40 lines of $LOG_OUT ──" >&2; tail -n 40 "$LOG_OUT" 2>/dev/null || true
  echo "── last 40 lines of $LOG_ERR ──" >&2; tail -n 40 "$LOG_ERR" 2>/dev/null || true
}

command -v splash >/dev/null 2>&1 || error "splash not found in PATH (brew tap incoai/tap && brew install incoai/tap/splash)"
[[ -n "$EXTERNAL_CACHE" && ! -d "$EXTERNAL_CACHE" ]] && error "EXTERNAL_CACHE path does not exist: $EXTERNAL_CACHE"

# ── 1. Start Splash ────────────────────────────────────────────────
info "Starting Splash server with model: $MODEL"
info "  max-memory=$MAX_MEMORY  max-cache-disk=$MAX_CACHE_DISK  persistent-cache=$PERSISTENT_CACHE"

SERVE_ARGS=(serve --model "$MODEL" --port "$SPLASH_PORT"
  --max-cache-disk "$MAX_CACHE_DISK"
  --max-memory "$MAX_MEMORY"
  --expert-memory auto
  --default-reasoning-effort "$REASONING_EFFORT"
  --thinking-token-budget "$THINKING_BUDGET")
[[ $PERSISTENT_CACHE -eq 1 ]] && SERVE_ARGS+=(--persistent-cache)
[[ -n "$EXTERNAL_CACHE" ]] && SERVE_ARGS+=(--cache-dir "$EXTERNAL_CACHE")

kill_pidfile "$SPLASH_PID_FILE" "Splash"
pkill -f "splash serve" 2>/dev/null || true
sleep 1
lsof -iTCP:"$SPLASH_PORT" -sTCP:LISTEN >/dev/null 2>&1 && warn "Port $SPLASH_PORT still in use after cleanup — Splash may fail to bind"

: > "$LOG_OUT"; : > "$LOG_ERR"
nohup splash "${SERVE_ARGS[@]}" > "$LOG_OUT" 2> "$LOG_ERR" &
SPLASH_PID=$!
echo "$SPLASH_PID" > "$SPLASH_PID_FILE"

info "Waiting for Splash to become ready (first model load downloads tens of GB)..."
READY=no
for i in {1..90}; do
  if curl -sf "http://127.0.0.1:${SPLASH_PORT}/status" >/dev/null 2>&1; then
    info "Splash is ready (pid $SPLASH_PID)"; READY=yes; break
  fi
  if ! kill -0 "$SPLASH_PID" 2>/dev/null; then tail_logs_on_failure; error "Splash exited early — see logs above"; fi
  sleep 2
done
[[ $READY != yes ]] && { tail_logs_on_failure; error "Splash did not become ready in time"; }

# ── 2. Start the dashboard ─────────────────────────────────────────
info "Starting Splash dashboard..."
if [[ ! -d "$DASH_DIR" ]]; then
  info "Cloning splash-dashboard..."
  git clone https://github.com/rickhuizinga/splash-dashboard.git "$DASH_DIR"
fi
kill_pidfile "$DASH_PID_FILE" "dashboard"
pkill -f "python3.*dash.py" 2>/dev/null || true
sleep 0.5
cd "$DASH_DIR"
if [[ -f "$DASH_DIR/start-dash.sh" ]]; then
  SPLASH_ENGINE_PORT="$SPLASH_PORT" nohup bash "$DASH_DIR/start-dash.sh" \
    --host 127.0.0.1 --port "$DASH_PORT" > "${HOME}/splash-dashboard.log" 2>&1 &
else
  DASH_ARGS=(--host 127.0.0.1 --port "$DASH_PORT" --engine-port "$SPLASH_PORT" --no-engine-key)
  nohup python3 dash.py "${DASH_ARGS[@]}" > "${HOME}/splash-dashboard.log" 2>&1 &
fi
DASH_PID=$!
echo "$DASH_PID" > "$DASH_PID_FILE"
sleep 2
kill -0 "$DASH_PID" 2>/dev/null && info "Dashboard → http://127.0.0.1:${DASH_PORT}" \
  || warn "Dashboard may have failed — see ~/splash-dashboard.log"

# ── 2b. Metrics + Grafana (brew services; optional) ─────────────────
# Prometheus (15 s scrape of the engine's native /metrics) keeps history;
# Grafana renders it. The leg is idempotent: running services are left alone,
# missing installs are skipped with a hint, never installed silently.
# One-time setup: brew install prometheus grafana, then point the Prometheus
# config (brew prefix etc/prometheus.yml) at localhost:<splash port>/metrics
# and provision Grafana (datasource + the splash-overview dashboard) under
# its provisioning dir — note Grafana 13 uses [paths] provisioning = ... plus
# permitted_provisioning_paths for external dirs, or provisioning silently no-ops.
if [[ $OPEN_METRICS -eq 1 ]] && command -v brew >/dev/null 2>&1; then
  for svc in prometheus grafana; do
    if brew services info "$svc" --json 2>/dev/null | grep -q '"running": *true'; then
      info "$svc already running."
    elif brew list --formula 2>/dev/null | grep -qx "$svc"; then
      info "Starting $svc..."
      brew services start "$svc" >/dev/null 2>&1 || warn "brew services start $svc failed"
    else
      info "$svc not installed — skipping metrics leg (brew install $svc to enable)."
    fi
  done
  sleep 2
  curl -sf http://127.0.0.1:3000/api/health >/dev/null 2>&1 \
    && info "Grafana → http://127.0.0.1:3000/d/splash-overview   (Prometheus → http://127.0.0.1:9090)" \
    || warn "Grafana not answering on :3000 yet — first start can take ~10 s."
fi

# ── 3. Launch DaVinci Resolve (skip if already running) ────────────
if pgrep -x "Resolve" >/dev/null 2>&1; then
  info "DaVinci Resolve already running."
else
  info "Opening DaVinci Resolve..."
  open -a "DaVinci Resolve" 2>/dev/null || open -a "DaVinci Resolve Studio" 2>/dev/null || warn "Could not open DaVinci Resolve"
  sleep 3
fi
open "http://127.0.0.1:${DASH_PORT}" 2>/dev/null || true

# ── 4. MacMon TUI in a second Terminal window ──────────────────────
if [[ $OPEN_MACMON -eq 1 ]] && command -v macmon >/dev/null 2>&1 && ! pgrep -x macmon >/dev/null 2>&1; then
  info "Opening MacMon in a new Terminal window..."
  MACMON_BIN="$(command -v macmon)"
  osascript -e 'tell application "Terminal" to activate' \
            -e "tell application \"Terminal\" to do script \"$MACMON_BIN\"" >/dev/null 2>&1 || true
fi

# ── 5. Launch Claude Code via Splash (takes over the terminal) ─────
info "Starting Claude Code (splash claude)..."
sleep 3
exec splash claude
