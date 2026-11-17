#!/bin/bash
# start.sh (installed as ~/bin/start.sh, linked at ~/start.sh)
# Starts Splash (Qwen3.8-Flash-Next IQ3_S) + dashboard + OpenCode
# DaVinci Resolve is NOT started automatically — OpenCode launches it on demand
# via MCP when a task needs it. Optional fallback: --27b
#
# Memory sizing was measured on an M5 Ultra 96 GB with Resolve Studio running
# concurrently (2026-10/11 iteration log preserved below — tune via env vars
# rather than editing):
#   MAX_MEMORY=56G  — leaves ~40 GB of slack for Resolve + macOS on 96 GB while
#                     keeping the KV pool ~10 GB (~770k tokens, 3x the 262k ctx).
#                     48G capped the KV pool below the 262k context (100% pinned,
#                     SSD spill); 64G left only 11-13% free + 7.6G swap during a
#                     Resolve UHD render. 56G is the measured middle. Smaller
#                     machines: try 24–32 GB; the engine prints its own
#                     recommended working set at startup.
#   MAX_CACHE_DISK=256G — 64 G saturated and started evicting warm prefixes;
#                     so did 128 G, in about two weeks of sustained agentic
#                     use (tier hits quota -> oldest-first eviction, a few
#                     percent of requests re-prefill). Raised 128G -> 256G on
#                     2026-11-14 after the tier hit 99.94% of quota; takes
#                     effect at NEXT launch only — never restart the live
#                     engine mid-session. Disk cache is cheap, RAM is not;
#                     size it to your volume's free space.
#   --expert-memory auto — splash >= 1.6.0 elastic expert store; a fixed size
#                     disables elasticity. Keep 'auto'.
#   THINKING_BUDGET=16384 — caps runaway deliberation so requests still answer.
#
# One-off overrides without editing:
#   MAX_MEMORY=32G MAX_CACHE_DISK=64G ./start.sh

set -euo pipefail

# Pin Homebrew into PATH even when invoked from a shell that never sourced
# the login profile; without it the metrics leg below can mis-detect
# installed formulae and brew's own errors stay invisible.
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# ── Configuration ──────────────────────────────────────────────────
MODEL_FLASH="ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:IQ3_S"
MODEL_27B="unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M"   # adjust if you use a different quant

SPLASH_PORT=8000
DASH_PORT=8280

MAX_CACHE_DISK="${MAX_CACHE_DISK:-256G}"
PERSISTENT_CACHE=1
MAX_MEMORY="${MAX_MEMORY:-56G}"
# Effort default for requests that set NONE (the Chat UI, and OpenCode — it sends no
# reasoning_effort, so this default is what chat gets; the engine logs it as
# "effort absent -> <this value>"). Flipped xhigh->medium on 2026-11-17g: the suite-wide
# agentic A/B scored both arms 16/18 while xhigh paid ~3x thinking tokens (10,538 vs
# 3,609 median) and ~40% more wall time — nothing measured for it. Reach for more
# thinking with --xhigh (see flags below); no need to edit this line.
REASONING_EFFORT="${REASONING_EFFORT:-medium}"
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

# OpenCode's project (and therefore which opencode.json applies — MCP permission
# defaults, the LSP plugin) is resolved from the cwd at handoff. The dashboard leg
# below cds into DASH_DIR and never cd's back, so the handoff explicitly cds here.
# Override:  RESOLVE_AI_PROJECT=~/benchmarks start.sh
PROJECT_DIR="${RESOLVE_AI_PROJECT:-$HOME/resolve-ai-workflow}"

# ── Parse flags ────────────────────────────────────────────────────
MODEL="$MODEL_FLASH"
for arg in "$@"; do
  case "$arg" in
    --27b) MODEL="$MODEL_27B" ;;
    --no-macmon) OPEN_MACMON=0 ;;
    --no-metrics) OPEN_METRICS=0 ;;
    # Thinking depth for this launch. Daily default is medium (see above);
    # --xhigh buys the deepest deliberation at ~3x thinking tokens and ~40%
    # more wall time, which the 2026-11-17g A/B measured as worth nothing on
    # these tasks — so pass it only when a hard task earns it.
    --low|--medium|--high|--xhigh) REASONING_EFFORT="${arg#--}" ;;
    --effort=*) REASONING_EFFORT="${arg#--effort=}" ;;
    -h|--help)
      echo "Usage: $0 [--27b] [--low|--medium|--high|--xhigh] [--no-macmon] [--no-metrics]"
      echo "  Thinking depth: --low | --medium (daily default) | --high | --xhigh, or REASONING_EFFORT=<value>"
      echo "  Env overrides: MAX_MEMORY=56G MAX_CACHE_DISK=256G EXTERNAL_CACHE=/path LAUNCH_RESOLVE_GUI=1 RESOLVE_AI_PROJECT=~/resolve-ai-workflow"
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
# The supervisor (python … -m server.server) RESPAWNS serve-native children with the
# OLD args — killing only the child leaves a stale-args engine bound to the port.
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

# ── 3. DaVinci Resolve: NOT auto-launched (default) ────────────────
# Headless Resolve is the default host: the MCP server launches it with
# -nogui on the first tool call that needs it, so booting the GUI here
# only races that. Switching to the GUI is a deliberate handoff (empty
# render queue, nothing rendering, no in-flight MCP mutations). Opt in
# to a GUI launch at boot with:  LAUNCH_RESOLVE_GUI=1 ./start.sh
if [[ ${LAUNCH_RESOLVE_GUI:-0} -eq 1 ]]; then
  if pgrep -x "Resolve" >/dev/null 2>&1; then
    info "DaVinci Resolve already running."
  else
    info "Opening DaVinci Resolve (LAUNCH_RESOLVE_GUI=1)..."
    open -a "DaVinci Resolve" 2>/dev/null || open -a "DaVinci Resolve Studio" 2>/dev/null || warn "Could not open DaVinci Resolve"
    sleep 3
  fi
else
  info "DaVinci Resolve: not launching (the MCP starts headless on demand;"
  info "  LAUNCH_RESOLVE_GUI=1 opens the GUI at boot)."
fi
open "http://127.0.0.1:${DASH_PORT}" 2>/dev/null || true

# ── 4. MacMon TUI in a second Terminal window ──────────────────────
if [[ $OPEN_MACMON -eq 1 ]] && command -v macmon >/dev/null 2>&1 && ! pgrep -x macmon >/dev/null 2>&1; then
  info "Opening MacMon in a new Terminal window..."
  MACMON_BIN="$(command -v macmon)"
  osascript -e 'tell application "Terminal" to activate' \
            -e "tell application \"Terminal\" to do script \"$MACMON_BIN\"" >/dev/null 2>&1 || true
fi

# ── 5. Launch OpenCode (takes over the terminal) ───────────────────
# The OpenCode handoff replaces the old `splash claude` bridge: OpenCode talks to
# the same local engine through the OpenAI-compatible endpoint (see the provider
# block written by install.sh). Rationale for the switch: HARNESS-MIGRATION.md.
# cd to PROJECT_DIR so the session gets the project's opencode.json (LSP plugin).
info "Starting OpenCode (project: $PROJECT_DIR)..."
cd "$PROJECT_DIR" 2>/dev/null || warn "PROJECT_DIR '$PROJECT_DIR' missing — starting OpenCode where we are"
sleep 3
exec opencode
