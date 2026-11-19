#!/bin/bash
# start.sh — starts the Splash engine, dashboard, metrics, and OpenCode.
# Installed as ~/bin/start.sh; ~/start.sh is a link to it.
#
# DaVinci Resolve is not launched here — the MCP server starts it headless on
# first use (launching the GUI here only races that).
#
# Tune via env vars rather than editing (sized for a 96 GB M5 Ultra with
# Resolve co-resident; smaller machines try MAX_MEMORY=24G–32G):
#   MAX_MEMORY=56G        leaves ~40 GB slack; 48G capped the KV pool below the
#                         262k context, 64G starved a Resolve UHD render.
#   MAX_CACHE_DISK=256G   64G and 128G both hit quota and evicted warm prefixes.
#                         Binds only at NEXT launch; never restart mid-session.
#   REASONING_EFFORT=medium  default when requests set none (see flags below).
#   THINKING_BUDGET=32768    cap on thinking per thinking request that sets none.
#                         Never bound at medium (largest step 2,348); xhigh consumed
#                         the previous 16384 in full. Binds only at NEXT launch.
#   QUEUE_SIZE=64         requests admitted at once, running or waiting; the rest get
#                         503. Splash default is 32 (measured ceiling 2026-11-19).
#                         Raise to 96 for a concurrent-load bench day.
# One-off example: MAX_MEMORY=32G MAX_CACHE_DISK=64G ./start.sh

set -euo pipefail

# Homebrew must be on PATH even from shells that never sourced the login profile,
# or the metrics leg mis-detects formulae and hides brew's errors.
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# ── Configuration ──────────────────────────────────────────────────
MODEL_FLASH="ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:IQ3_S"
MODEL_27B="unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M"   # --27b fallback; adjust quant if yours differs

SPLASH_PORT=8000
DASH_PORT=8280

MAX_CACHE_DISK="${MAX_CACHE_DISK:-256G}"
PERSISTENT_CACHE=1
MAX_MEMORY="${MAX_MEMORY:-56G}"
# medium by default: the 2026-11-17g agentic A/B scored xhigh identical to medium
# at ~3x the thinking tokens. Use --xhigh only when a task earns it.
REASONING_EFFORT="${REASONING_EFFORT:-medium}"
# Budget-abiding: the engine charges for thinking it generates, not for the ceiling,
# so a larger cap is free while unused and only bounds a runaway step. 32768 is ~14x
# the largest single step seen at medium (2,348) and ~2x the xhigh worst case.
THINKING_BUDGET="${THINKING_BUDGET:-32768}"   # caps runaway thinking; 16384->32768 on 2026-11-19: medium peaks ~2.4k/step (never bound), but xhigh once consumed all 16k (16,385 tok) and long written instructions need the headroom
# Requests admitted at once, running or waiting; anything past this gets HTTP 503
# (frontend_overloaded). Splash default is 32, and the 2026-11-19 KV run proved that is
# the binding ceiling for concurrent-load work: w32 admitted, w33 refused instantly with
# waiting_concurrency=0 (refused, never queued). 64 gives the KV stage room to show real
# queueing/spill behaviour and leaves slack over one interactive session. Bench day only:
# QUEUE_SIZE=96 ./start.sh if you want to probe past 64 concurrent streams.
QUEUE_SIZE="${QUEUE_SIZE:-64}"

# Optional: move the persistent cache to an external SSD,
# e.g. EXTERNAL_CACHE="/Volumes/YourExternalSSD/splash-cache"
EXTERNAL_CACHE=""

OPEN_MACMON=1               # second Terminal window running the macmon TUI
OPEN_METRICS=1              # Prometheus (:9090) + Grafana (:3000); --no-metrics skips

LOG_DIR="${HOME}/Library/Logs/splash"
LOG_OUT="${LOG_DIR}/splash.out.log"
LOG_ERR="${LOG_DIR}/splash.err.log"
mkdir -p "$LOG_DIR"
[[ -L "$LOG_OUT" ]] && rm -f "$LOG_OUT"

DASH_DIR="${HOME}/splash-dashboard"
DASH_PID_FILE="${HOME}/.splash-dashboard.pid"
SPLASH_PID_FILE="${HOME}/.splash.pid"

# Which opencode.json applies at handoff comes from the cwd — the dashboard leg
# below cds away, so the OpenCode step cds back here explicitly.
# Override: RESOLVE_AI_PROJECT=~/benchmarks start.sh
PROJECT_DIR="${RESOLVE_AI_PROJECT:-$HOME/resolve-ai-workflow}"

# ── Parse flags ────────────────────────────────────────────────────
MODEL="$MODEL_FLASH"
for arg in "$@"; do
  case "$arg" in
    --27b) MODEL="$MODEL_27B" ;;
    --no-macmon) OPEN_MACMON=0 ;;
    --no-metrics) OPEN_METRICS=0 ;;
    --low|--medium|--high|--xhigh) REASONING_EFFORT="${arg#--}" ;;
    --effort=*) REASONING_EFFORT="${arg#--effort=}" ;;
    -h|--help)
      echo "Usage: $0 [--27b] [--low|--medium|--high|--xhigh] [--no-macmon] [--no-metrics]"
      echo "  Thinking depth: --low | --medium (daily default) | --high | --xhigh, or REASONING_EFFORT=<value>"
      echo "  Env overrides: MAX_MEMORY=56G MAX_CACHE_DISK=256G QUEUE_SIZE=64 EXTERNAL_CACHE=/path RESOLVE_AI_PROJECT=~/resolve-ai-workflow"
      exit 0 ;;
    *) echo "Unknown argument: $arg (try --help)" >&2; exit 1 ;;
  esac
done

info()  { echo "→ $*"; }
warn()  { echo "⚠ $*"; }
error() { echo "✗ $*" >&2; exit 1; }

case "$REASONING_EFFORT" in
  low|medium|high|xhigh) ;;
  *) error "invalid effort '$REASONING_EFFORT' — use low, medium, high or xhigh" ;;
esac

[[ "$QUEUE_SIZE" =~ ^[0-9]+$ ]] && (( QUEUE_SIZE >= 1 )) \
  || error "invalid QUEUE_SIZE '$QUEUE_SIZE' — must be a positive integer (splash default 32)"

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
command -v opencode >/dev/null 2>&1 || error "opencode not found in PATH (run install.sh first)"
[[ -n "$EXTERNAL_CACHE" && ! -d "$EXTERNAL_CACHE" ]] && error "EXTERNAL_CACHE path does not exist: $EXTERNAL_CACHE"

# ── 1. Start Splash ────────────────────────────────────────────────
info "Starting Splash server with model: $MODEL"
info "  max-memory=$MAX_MEMORY  max-cache-disk=$MAX_CACHE_DISK  persistent-cache=$PERSISTENT_CACHE"
info "  default-reasoning-effort=$REASONING_EFFORT  thinking-token-budget=$THINKING_BUDGET"
info "  queue-size=$QUEUE_SIZE (splash default 32; beyond this the frontend returns 503)"

SERVE_ARGS=(serve --model "$MODEL" --port "$SPLASH_PORT"
  --max-cache-disk "$MAX_CACHE_DISK"
  --max-memory "$MAX_MEMORY"
  --expert-memory auto          # elastic expert store (splash >= 1.6.0); a fixed size disables elasticity
  --default-reasoning-effort "$REASONING_EFFORT"
  --thinking-token-budget "$THINKING_BUDGET"
  --queue-size "$QUEUE_SIZE")
[[ $PERSISTENT_CACHE -eq 1 ]] && SERVE_ARGS+=(--persistent-cache)
[[ -n "$EXTERNAL_CACHE" ]] && SERVE_ARGS+=(--cache-dir "$EXTERNAL_CACHE")

kill_pidfile "$SPLASH_PID_FILE" "Splash"
pkill -f "splash serve" 2>/dev/null || true
# Kill the supervisor too: it respawns serve-native children with the OLD args.
pkill -f -- "-m server[.]server" 2>/dev/null || true
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
# Idempotent: running services are left alone, missing installs are skipped with
# a hint, never installed silently. One-time setup: brew install prometheus
# grafana, point Prometheus at localhost:$SPLASH_PORT/metrics, and provision
# Grafana (Grafana 13 needs [paths] provisioning + permitted_provisioning_paths
# for external dirs, or provisioning silently no-ops).
if [[ $OPEN_METRICS -eq 1 ]] && command -v brew >/dev/null 2>&1; then
  for svc in prometheus grafana; do
    if brew services info "$svc" --json 2>/dev/null | grep -q '"running": *true'; then
      info "$svc already running."
    elif formulas="$(brew list --formula 2>/dev/null)"; then
      if grep -qx "$svc" <<<"$formulas"; then
        info "Starting $svc..."
        brew services start "$svc" || warn "brew services start $svc failed (see brew output above)"
      else
        info "$svc not installed — skipping metrics leg (brew install $svc to enable)."
      fi
    else
      warn "brew list FAILED — can't tell whether $svc is installed; skipping it."
      warn "If this recurs, run 'brew doctor'."
    fi
  done
  sleep 2
  curl -sf http://127.0.0.1:3000/api/health >/dev/null 2>&1 \
    && info "Grafana → http://127.0.0.1:3000/d/splash-overview   (Prometheus → http://127.0.0.1:9090)" \
    || warn "Grafana not answering on :3000 yet — first start can take ~10 s."
fi

open "http://127.0.0.1:${DASH_PORT}" 2>/dev/null || true

# ── 3. MacMon TUI in a second Terminal window ──────────────────────
if [[ $OPEN_MACMON -eq 1 ]] && command -v macmon >/dev/null 2>&1 && ! pgrep -x macmon >/dev/null 2>&1; then
  info "Opening MacMon in a new Terminal window..."
  MACMON_BIN="$(command -v macmon)"
  osascript -e 'tell application "Terminal" to activate' \
            -e "tell application \"Terminal\" to do script \"$MACMON_BIN\"" >/dev/null 2>&1 || true
fi

# ── 4. Launch OpenCode (takes over the terminal) ───────────────────
# Replaces the old `splash claude` bridge; rationale: HARNESS-MIGRATION.md.
info "Starting OpenCode (project: $PROJECT_DIR)..."
cd "$PROJECT_DIR" 2>/dev/null || warn "PROJECT_DIR '$PROJECT_DIR' missing — starting OpenCode where we are"
sleep 3
exec opencode
