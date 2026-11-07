#!/usr/bin/env bash
# install.sh — one-shot installer for the Resolve AI workstation stack.
#
# What it installs:
#   1. Homebrew (if missing)
#   2. Splash (local LLM engine, incoai/tap)
#   3. Claude Code CLI (official native installer)
#   4. ffmpeg + ffprobe, whisper.cpp, macmon, Node.js
#   5. Community davinci-resolve MCP (Python server + advanced Node server),
#      wired into Claude Code
#   6. Official Blackmagic ResolveMCP (registered if the Studio app provides it)
#   7. start.sh / stop.sh into ~/bin
#   8. Claude Code permission defaults for the MCP tools
#
# Opt-in, not installed by default:
#   --vision   face/mouth analysis layer (its own Python 3.12 venv + model files).
#              MediaPipe + OpenCV YuNet/SFace: ~54 MB of models, every one of them with a
#              stated licence (YuNet MIT, SFace Apache-2.0). Detection, identity, landmarks
#              and mouth state in one probe script — see vision/README.md.
#
# Verified against: macOS 27.2 arm64, DaVinci Resolve Studio 21.2, Splash 1.6.0,
# MCP 4.19.3, node 26.x, ffmpeg 9.x. Python 3.11+ required by the MCP installer.
# The --vision path was verified end-to-end on that host on 2026-11-06: fresh venv, every
# pin installed at its pinned version, models downloaded, probe run against real footage.
#
# Run:  bash install.sh [--vision]

set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { printf "${BLUE}→${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}✓${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}⚠${NC} %s\n" "$*"; }
die()  { printf "${RED}✗${NC} %s\n" "$*" >&2; exit 1; }

# ── 0. Options ─────────────────────────────────────────────────────────────
VISION=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vision) VISION=1; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see: bash install.sh --help)" ;;
  esac
done

echo "============================================================"
echo "  Resolve AI workstation installer"
echo "  Splash + Claude Code + DaVinci Resolve MCPs (+ Blender)"
echo "============================================================"
echo

command -v brew >/dev/null 2>&1 || [[ -x /opt/homebrew/bin/brew ]] || \
  die "Install Homebrew first: https://brew.sh  (Apple Silicon Macs only for this stack)"
[[ -x /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
ok "Homebrew $(brew --version | head -1)"

# ── 1. Splash (the local LLM engine) ──────────────────────────────────────
log "Installing/updating Splash (incoai/tap)..."
brew tap incoai/tap 2>/dev/null || true
brew install incoai/tap/splash || brew upgrade incoai/tap/splash
ok "Splash $(splash --version 2>/dev/null || echo installed)"

# ── 2. Claude Code CLI (native installer, no Node dependency) ─────────────
log "Installing Claude Code CLI..."
curl -fsSL https://claude.ai/install.sh | bash || warn "installer non-zero (may already be current)"
export PATH="$HOME/.local/bin:$PATH"
grep -q '\.local/bin' ~/.zprofile 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zprofile
command -v claude >/dev/null 2>&1 && ok "Claude Code $(claude --version 2>/dev/null)" || \
  die "claude still not on PATH — open a new terminal and re-run"

# ── 3. Media + support tools ───────────────────────────────────────────────
log "Installing ffmpeg, whisper.cpp, macmon, node..."
brew install ffmpeg || brew upgrade ffmpeg
brew install whisper.cpp || brew install whisper-cpp || warn "whisper formula failed (optional)"
brew install macmon    || warn "macmon failed (optional — memory/GPU telemetry)"
brew install node      || true
ok "ffmpeg $(ffmpeg -version 2>/dev/null | head -1 | cut -d' ' -f3) · node $(node --version 2>/dev/null)"

# ── 4. Community DaVinci Resolve MCP ───────────────────────────────────────
# Installs a managed tree (Python venv + Node advanced server) under
# ~/Library/Application Support/davinci-resolve-mcp and wires Claude Code.
log "Installing community davinci-resolve MCP (registers the 'davinci-resolve' and 'davinci-resolve-advanced' servers)..."
npx -y davinci-resolve-mcp@latest setup --clients claude-code || \
  npx -y davinci-resolve-mcp@latest setup || \
  warn "MCP setup needs a terminal — re-run: npx davinci-resolve-mcp setup"
ok "Community MCP attempted. Verify later: claude mcp list"
# Future updates:  npx -y davinci-resolve-mcp@latest sync   (then reconnect servers)

# ── 5. Official Blackmagic ResolveMCP (Studio 21.1+ ships it inside the app) ─
OFFICIAL_MCP=""
for p in "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Applications/ResolveMCP" \
         "/Applications/DaVinci Resolve.app/Contents/Applications/ResolveMCP"; do
  [[ -x "$p" ]] && OFFICIAL_MCP="$p" && break
done
if [[ -n "$OFFICIAL_MCP" ]]; then
  log "Registering official ResolveMCP as 'DaVinci Resolve'..."
  claude mcp add "DaVinci Resolve" -- "$OFFICIAL_MCP" 2>/dev/null || true
  ok "Official ResolveMCP registered"
else
  warn "Official ResolveMCP not found — requires DaVinci Resolve Studio 21.1+"
fi

# ── 6. Blender (optional but recommended for titles/stings) ────────────────
if [[ ! -d /Applications/Blender.app ]]; then
  log "Blender not found. Install 4.x/5.x LTS from blender.org (or: brew install --cask blender)."
  log "The headless title pipeline in blender/ was verified on Blender 5.2.3 LTS."
fi

# ── 7. Vision add-on (opt-in: --vision) ────────────────────────────────────
# Deliberately not part of the default install: its own Python 3.12, ~54 MB of model files,
# and MediaPipe/OpenCV wheels (vision/README.md). Licences are stated per model there.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$VISION" == 1 ]]; then
  log "Vision add-on (own venv, so a server repair can't wipe it)..."
  bash "$REPO_DIR/vision/install-vision.sh" || die "vision install failed — see vision/README.md"
else
  log "Skipping the vision add-on. Add it any time: bash install.sh --vision   (or run vision/install-vision.sh)"
fi

# ── 8. start.sh / stop.sh into ~/bin ───────────────────────────────────────
log "Installing start.sh / stop.sh into ~/bin ..."
mkdir -p "$HOME/bin"
cp "$REPO_DIR/start.sh" "$HOME/bin/start-resolve-ai.sh"
cp "$REPO_DIR/stop.sh"  "$HOME/bin/stop-resolve-ai.sh"
chmod +x "$HOME/bin/start-resolve-ai.sh" "$HOME/bin/stop-resolve-ai.sh"
grep -q 'HOME/bin' ~/.zprofile 2>/dev/null || echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zprofile
ok "Launcher installed (start-resolve-ai.sh / stop-resolve-ai.sh)"

# ── 9. Claude Code permissions for the MCP tools ────────────────────────────
# The MCP servers are deliberately guarded (dry-run defaults, confirm tokens,
# auto-archiving destructive ops), so most users auto-approve their tools.
# Review ~/.claude/settings.json afterwards.
log "Writing MCP permission defaults to ~/.claude/settings.json..."
python3 - <<'PY'
import json, os
path = os.path.expanduser("~/.claude/settings.json")
data = {}
if os.path.exists(path):
    try: data = json.load(open(path))
    except Exception: data = {}
perms = data.setdefault("permissions", {})
allow = perms.setdefault("allow", [])
for pat in ["mcp__davinci-resolve__*", "mcp__davinci-resolve-advanced__*", "mcp__DaVinci_Resolve__*"]:
    if pat not in allow: allow.append(pat)
json.dump(data, open(path, "w"), indent=2)
print("wrote", path)
PY
ok "Permissions set"

# ── 10. Verification ───────────────────────────────────────────────────────
echo
echo "============================================================"
echo "  Verification"
echo "============================================================"
printf "  splash : "; command -v splash >/dev/null && ok "$(splash --version 2>/dev/null)" || warn missing
printf "  claude : "; command -v claude >/dev/null && ok "$(claude --version 2>/dev/null)" || warn missing
printf "  ffmpeg : "; command -v ffmpeg >/dev/null && ok present || warn missing
if [[ "$VISION" == 1 ]]; then
  printf "  vision : "
  if [[ -x "$HOME/resolve-vision-venv312/bin/python" ]] && [[ -f "$HOME/resolve-vision-models/face_landmarker.task" ]]; then
    ok "$("$HOME/resolve-vision-venv312/bin/python" -c 'import mediapipe,cv2;print("mediapipe",mediapipe.__version__,"· opencv",cv2.__version__,"· YuNet+SFace",hasattr(cv2,"FaceDetectorYN") and hasattr(cv2,"FaceRecognizerSF"))' 2>/dev/null || echo present)"
  else
    warn "venv or models missing — re-run: bash vision/install-vision.sh"
  fi
fi
echo
log "Registered MCP servers:"
claude mcp list 2>/dev/null || warn "run 'claude mcp list' in a new terminal"
echo
echo "Next steps:"
echo "  1. Open a NEW terminal, then:  start-resolve-ai.sh"
echo "     (first run downloads the model — tens of GB; keep the terminal open)"
echo "  2. Dashboard:  http://127.0.0.1:8280   Engine chat UI: http://127.0.0.1:8000"
echo "  3. Inside Claude Code: /mcp  →  reconnect the Resolve servers once Resolve is up"
echo "  4. Ask: 'what is the current timeline and its items?' — expect read-only answers."
echo "  5. Stop cleanly:  stop-resolve-ai.sh"
