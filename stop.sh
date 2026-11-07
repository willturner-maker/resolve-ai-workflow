#!/bin/bash
# stop-resolve-ai.sh
# Cleanly shuts down Splash, the dashboard, and related processes

set -euo pipefail

SPLASH_PID_FILE="${HOME}/.splash.pid"
SPLASH_PID_FILE_ALT="${HOME}/.splash-server.pid"
DASH_PID_FILE="${HOME}/.splash-dashboard.pid"

info()  { echo "→ $*"; }
warn()  { echo "⚠ $*"; }

# ── 1. Stop Splash (handles both pid-file spellings) ───────────────
info "Stopping Splash..."
stopped=no
for pf in "$SPLASH_PID_FILE" "$SPLASH_PID_FILE_ALT"; do
  if [[ -f "$pf" ]]; then
    pid=$(cat "$pf" 2>/dev/null || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      for i in {1..10}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
      done
      kill -9 "$pid" 2>/dev/null || true
      info "Splash stopped (pid $pid)"
      stopped=yes
    else
      warn "Pid file $pf present but process not running"
    fi
    rm -f "$pf"
  fi
done
if [[ $stopped == no ]]; then
  # Fallback: kill by name (also catches the serve-native engine child
  # and any instance the Claude Code CLI spawned without a pid file)
  if pkill -f "splash serve" 2>/dev/null; then
    info "Splash stopped (by process name)"
  else
    info "Splash was not running"
  fi
fi

# ── 2. Stop Dashboard ──────────────────────────────────────────────
info "Stopping dashboard..."
if [[ -f "$DASH_PID_FILE" ]]; then
  pid=$(cat "$DASH_PID_FILE" 2>/dev/null || true)
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 0.5
    kill -9 "$pid" 2>/dev/null || true
    info "Dashboard stopped (pid $pid)"
  else
    warn "Dashboard pid file present but process not running"
  fi
  rm -f "$DASH_PID_FILE"
elif pkill -f "python3.*dash.py" 2>/dev/null; then
  info "Dashboard stopped (by process name)"
fi

# ── 2b. Stop the metrics leg (Prometheus + Grafana brew services) ───
if command -v brew >/dev/null 2>&1; then
  for svc in prometheus grafana; do
    if brew services info "$svc" --json 2>/dev/null | grep -q '"running": *true'; then
      info "Stopping $svc..."
      brew services stop "$svc" >/dev/null 2>&1 || warn "brew services stop $svc failed"
    fi
  done
fi

# ── 3. Stop any leftover splash agent processes ────────────────────
pkill -f "splash claude" 2>/dev/null || true

info "Done. Splash and dashboard are shut down."
info "(DaVinci Resolve was left running — close it manually if desired.)"
