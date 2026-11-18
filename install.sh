#!/usr/bin/env bash
# install.sh — one-shot installer for the Resolve AI workstation stack.
#
# What it installs:
#   1. Homebrew (if missing)
#   2. Splash (local LLM engine, incoai/tap)
#   3. OpenCode (open-source agent harness — replaced Claude Code on 2026-11-16,
#      see HARNESS-MIGRATION.md for the measurement that drove the switch)
#   4. ffmpeg + ffprobe, whisper.cpp, macmon, Node.js
#   5. Community davinci-resolve MCP (Python server + advanced Node server),
#      wired into OpenCode
#   6. Official Blackmagic ResolveMCP (registered if the Studio app provides it)
#   7. start.sh / stop.sh into ~/bin
#   8. OpenCode global config for local Splash (V2 shape: providers/settings/
#      mcp.servers) — MERGED into an existing config, never clobbered
#
# Opt-in, not installed by default:
#   --vision   face/mouth analysis layer (its own Python 3.12 venv + model files).
#              MediaPipe + OpenCV YuNet/SFace: ~54 MB of models, every one of them with a
#              stated licence (YuNet MIT, SFace Apache-2.0). Detection, identity, landmarks
#              and mouth state in one probe script — see vision/README.md.
#   --lsp      LSP tool + post-edit diagnostics for OpenCode V2 (it ships with no LSP
#              runtime). Clones the community plugin (christensenjairus/
#              opencode-v2-lsp-support) to ~/tools and writes a project-scoped
#              opencode.json in this repo. Never wired into the global config —
#              project-scoping is deliberate: the agent pool stays provably plugin-free.
#
# Reference host as of 2026-11-18: macOS 26.x arm64, DaVinci Resolve Studio 21.2, Splash 1.7.0,
# community MCP 5.3.3, OpenCode v2.3.1, node 26.x, ffmpeg 9.x (versions re-read live on that
# date; the installer itself last ran end-to-end on the reference host before the 5.3.x moves).
# Python 3.11+ required by the MCP installer. The OpenCode path is the daily-driver configuration
# on the reference host (the resolve-agentic benchmark waves run against exactly this stack).
#
# Run:  bash install.sh [--vision] [--lsp]

set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { printf "${BLUE}→${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}✓${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}⚠${NC} %s\n" "$*"; }
die()  { printf "${RED}✗${NC} %s\n" "$*" >&2; exit 1; }

# ── 0. Options ─────────────────────────────────────────────────────────────
VISION=0
LSP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vision) VISION=1; shift ;;
    --lsp)    LSP=1; shift ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see: bash install.sh --help)" ;;
  esac
done

echo "============================================================"
echo "  Resolve AI workstation installer (OpenCode)"
echo "  Splash + OpenCode + DaVinci Resolve MCPs (+ Blender)"
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

# ── 2. OpenCode (the agent harness) ────────────────────────────────────────
log "Installing OpenCode..."
if command -v opencode >/dev/null 2>&1; then
  ok "OpenCode already present: $(opencode --version 2>/dev/null || echo installed)"
else
  curl -fsSL https://opencode.ai/install | bash || npm install -g opencode-ai || die "OpenCode install failed"
  export PATH="$HOME/.local/bin:$PATH"
  grep -q '\.local/bin' ~/.zprofile 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zprofile
  command -v opencode >/dev/null 2>&1 && ok "OpenCode $(opencode --version 2>/dev/null)" || \
    die "opencode still not on PATH — open a new terminal and re-run"
fi

# ── 3. Media + support tools ───────────────────────────────────────────────
log "Installing ffmpeg, whisper.cpp, macmon, node..."
brew install ffmpeg || brew upgrade ffmpeg
brew install whisper.cpp || brew install whisper-cpp || warn "whisper formula failed (optional)"
brew install macmon    || warn "macmon failed (optional — memory/GPU telemetry)"
brew install node      || true
ok "ffmpeg $(ffmpeg -version 2>/dev/null | head -1 | cut -d' ' -f3) · node $(node --version 2>/dev/null)"

# ── 4. Community DaVinci Resolve MCP ───────────────────────────────────────
# Installs a managed tree (Python venv + Node advanced server) under
# ~/Library/Application Support/davinci-resolve-mcp and registers the servers
# in ~/.config/opencode/opencode.json (client id: opencode).
log "Installing community davinci-resolve MCP (registers the 'davinci-resolve' and 'davinci-resolve-advanced' servers)..."
npx -y davinci-resolve-mcp@latest setup --clients opencode || \
  npx -y davinci-resolve-mcp@latest setup || \
  warn "MCP setup needs a terminal — re-run: npx davinci-resolve-mcp setup"
ok "Community MCP attempted. Verify later: opencode mcp list"
# Future updates:  npx -y davinci-resolve-mcp@latest sync   (then reconnect servers)

# ── 5. Official Blackmagic ResolveMCP (Studio 21.1+ ships it inside the app) ─
OFFICIAL_MCP=""
for p in "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Applications/ResolveMCP" \
         "/Applications/DaVinci Resolve.app/Contents/Applications/ResolveMCP"; do
  [[ -x "$p" ]] && OFFICIAL_MCP="$p" && break
done
if [[ -n "$OFFICIAL_MCP" ]]; then
  log "Registering official ResolveMCP as 'DaVinci Resolve'..."
  opencode mcp add --global "DaVinci Resolve" -- "$OFFICIAL_MCP" 2>/dev/null || true
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

# ── 8. LSP add-on (opt-in: --lsp) ──────────────────────────────────────────
# OpenCode V2 ships with no LSP runtime: no lsp tool, no post-edit diagnostics,
# and the lsp config key is inert on its own (live-probed on v2.3.0). The community
# plugin restores both. Project-scoped on purpose — keep it OUT of the global
# config so agent pools (benchmark or sealed automation) stay provably plugin-free.
if [[ "$LSP" == 1 ]]; then
  PLUGIN_DIR="$HOME/tools/opencode-v2-lsp-support"
  log "LSP plugin -> $PLUGIN_DIR"
  if [[ -d "$PLUGIN_DIR/.git" ]]; then
    (cd "$PLUGIN_DIR" && git pull --ff-only) || warn "plugin pull failed (offline?) — continuing"
  else
    mkdir -p "$HOME/tools"
    git clone https://github.com/christensenjairus/opencode-v2-lsp-support.git "$PLUGIN_DIR" || \
      die "plugin clone failed"
  fi
  (cd "$PLUGIN_DIR" && npm ci --ignore-scripts) || warn "npm ci failed — Rust/Cargo detection only, other languages still load"
  command -v pyright-langserver >/dev/null 2>&1 || warn "pyright-langserver not on PATH — install: npm i -g pyright (or brew install pyright)"
  command -v bash-language-server >/dev/null 2>&1 || warn "bash-language-server not on PATH — install: npm i -g bash-language-server"
  log "Writing project-scoped opencode.json (plugins + lsp map) into $REPO_DIR ..."
  OPENCODE_PLUGIN_PATH="$PLUGIN_DIR" REPO_JSON="$REPO_DIR/opencode.json" python3 - <<'PY'
import json, os
path = os.environ["REPO_JSON"]; plugin = os.environ["OPENCODE_PLUGIN_PATH"]
data = {}
if os.path.exists(path):
    try: data = json.load(open(path))
    except Exception: data = {}
plugins = data.setdefault("plugins", [])
if plugin not in plugins: plugins.append(plugin)
lsp = data.setdefault("lsp", {})
lsp.setdefault("pyright", {"command": ["pyright-langserver", "--stdio"]})
lsp.setdefault("bash", {"command": ["bash-language-server", "start"]})
json.dump(data, open(path, "w"), indent=2)
print("wrote", path)
PY
  grep -q '^opencode.json' "$REPO_DIR/.gitignore" 2>/dev/null || \
    printf '\n# local tooling (LSP plugin path is machine-specific)\nopencode.json\n' >> "$REPO_DIR/.gitignore"
  ok "LSP add-on wired (project-scoped). Verify in OpenCode here: ask 'do you have an lsp tool?'"
else
  log "Skipping the LSP add-on. Add it any time: bash install.sh --lsp"
fi

# ── 9. start.sh / stop.sh into ~/bin ───────────────────────────────────────
log "Installing start.sh / stop.sh into ~/bin ..."
mkdir -p "$HOME/bin"
cp "$REPO_DIR/start.sh" "$HOME/bin/start.sh"
cp "$REPO_DIR/stop.sh"  "$HOME/bin/stop.sh"
chmod +x "$HOME/bin/start.sh" "$HOME/bin/stop.sh"
grep -q 'HOME/bin' ~/.zprofile 2>/dev/null || echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zprofile
ok "Launcher installed (start.sh / stop.sh in ~/bin)"

# ── 10. OpenCode config for Splash / Qwen + MCP permissions ────────────────
# MERGE-ONLY: preserves existing providers, MCP servers (the community installer
# already wrote them), plugins, and anything else in the global config.
# V2 shape: providers.<name>.{package,settings,models} — NOT the V1 provider/npm shape.
log "Merging Splash provider + model default into ~/.config/opencode/opencode.json..."
mkdir -p "$HOME/.config/opencode"
MODEL_ID="ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:IQ3_S" OPENCODE_CONFIG_PATH="$HOME/.config/opencode/opencode.json" python3 - <<'PY'
import json, os
path = os.environ["OPENCODE_CONFIG_PATH"]; model = os.environ["MODEL_ID"]
data = {}
if os.path.exists(path):
    try: data = json.load(open(path))
    except Exception: data = {}
prov = data.setdefault("providers", {}).setdefault("splash", {})
prov.setdefault("name", "Splash (Qwen3.8-Flash-Next)")
prov.setdefault("package", "aisdk:@ai-sdk/openai-compatible")
prov.setdefault("settings", {}).setdefault("baseURL", "http://127.0.0.1:8000/v1")
prov.setdefault("settings", {}).setdefault("apiKey", "none")
prov.setdefault("models", {}).setdefault(model, {
    "name": "Qwen3.8-Flash-Next IQ3_S",
    "limit": {"context": 262144, "output": 16384},
})
data.setdefault("model", f"splash/{model}")
# The MCP servers are deliberately guarded (dry-run defaults, confirm tokens,
# auto-archiving destructive ops), so most users auto-approve their tools.
perms = data.setdefault("permissions", [])
for pat in ["davinci-resolve*", "DaVinci Resolve*"]:
    if not any(p.get("action") == pat for p in perms):
        perms.append({"action": pat, "resource": "*", "effect": "allow"})
json.dump(data, open(path, "w"), indent=2)
print("merged", path)
PY
ok "OpenCode config merged (existing entries preserved — review it afterwards)"

# ── 11. Verification ───────────────────────────────────────────────────────
echo
echo "============================================================"
echo "  Verification"
echo "============================================================"
printf "  splash  : "; command -v splash >/dev/null && ok "$(splash --version 2>/dev/null)" || warn missing
printf "  opencode: "; command -v opencode >/dev/null && ok "$(opencode --version 2>/dev/null)" || warn missing
printf "  ffmpeg  : "; command -v ffmpeg >/dev/null && ok present || warn missing
if [[ "$LSP" == 1 ]]; then
  printf "  lsp     : "; [[ -d "$HOME/tools/opencode-v2-lsp-support" ]] && ok "plugin cloned" || warn missing
fi
if [[ "$VISION" == 1 ]]; then
  printf "  vision  : "
  if [[ -x "$HOME/resolve-vision-venv312/bin/python" ]] && [[ -f "$HOME/resolve-vision-models/face_landmarker.task" ]]; then
    ok "$("$HOME/resolve-vision-venv312/bin/python" -c 'import mediapipe,cv2;print("mediapipe",mediapipe.__version__,"· opencv",cv2.__version__,"· YuNet+SFace",hasattr(cv2,"FaceDetectorYN") and hasattr(cv2,"FaceRecognizerSF"))' 2>/dev/null || echo present)"
  else
    warn "venv or models missing — re-run: bash vision/install-vision.sh"
  fi
fi
echo
log "Registered MCP servers:"
opencode mcp list 2>/dev/null || warn "run 'opencode mcp list' in a new terminal"
echo
echo "Next steps:"
echo "  1. Open a NEW terminal, then:  start.sh"
echo "     (first run downloads the model — tens of GB; keep the terminal open)"
echo "  2. Dashboard:  http://127.0.0.1:8280   Engine chat UI: http://127.0.0.1:8000"
echo "  3. Inside OpenCode: /models  →  confirm Splash/Qwen is selected"
echo "  4. Ask: 'what is the current timeline and its items?' — expect read-only answers."
echo "  5. Stop cleanly:  stop.sh"
echo
echo "Why OpenCode and not Claude Code? See HARNESS-MIGRATION.md (2026-11-16 benchmark evidence)."
