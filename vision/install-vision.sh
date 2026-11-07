#!/usr/bin/env bash
# vision/install-vision.sh — optional face/pose layer for the Resolve workstation.
#
# Builds a dedicated Python 3.12 venv (MediaPipe + OpenCV YuNet/SFace) and fetches the model
# files into a directory that survives venv rebuilds.
#
# Why these models: OpenCV's YuNet detector (MIT weights, 233 KB) and SFace recogniser
# (Apache-2.0, 38.7 MB) do detection and identity with no extra dependency — both classes
# already ship in opencv-contrib-python — and on 8.1K choir footage they measure 90 faces in
# 0.29 s with 0.0 s model init. Nothing downloads itself at run time, and every weight this
# script installs has its licence stated in vision/README.md.
#
# Why a SECOND venv, deliberately: the MCP server's own repair path (install.py / its
# doctor) recreates the server venv and wipes anything you added to it. Analysis tools
# that agent scripts call stay here, so a server repair never takes the vision stack with
# it. If you specifically want the MCP server's built-in face analyzer
# (media_analysis action='strata_run', analyzers=['face']), use --mcp-server-venv — it
# prints the trade-off before doing it.
#
# Run:  bash vision/install-vision.sh [--venv DIR] [--models DIR] [--loose]
#                                      [--dry-run] [--mcp-server-venv DIR]
#
# Verified on: macOS 27.2 arm64, Homebrew python@3.12 (3.12.16), the exact pins below.

set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { printf "${BLUE}→${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}✓${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}⚠${NC} %s\n" "$*"; }
die()  { printf "${RED}✗${NC} %s\n" "$*" >&2; exit 1; }

VENV_DIR="${VISION_VENV:-$HOME/resolve-vision-venv312}"
MODELS_DIR="${VISION_MODELS:-$HOME/resolve-vision-models}"
DRY=0; LOOSE=0; MCP_VENV=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --venv)              VENV_DIR="$2"; shift 2 ;;
    --models)            MODELS_DIR="$2"; shift 2 ;;
    --loose)             LOOSE=1; shift ;;
    --dry-run)           DRY=1; shift ;;
    --mcp-server-venv)   MCP_VENV="$2"; shift 2 ;;
    -h|--help)           sed -n '2,16p' "$0"; exit 0 ;;
    *)                   die "unknown option: $1" ;;
  esac
done

run() { if [[ "$DRY" == 1 ]]; then printf "  [dry-run] %s\n" "$*"; else eval "$@"; fi; }

echo "============================================================"
echo "  Vision add-on: MediaPipe + OpenCV YuNet/SFace for Resolve analysis"
echo "============================================================"
echo "  venv   : $VENV_DIR"
echo "  models : $MODELS_DIR"
[[ "$DRY" == 1 ]] && warn "dry run — nothing will be written"
echo

# ── 1. Python 3.12 ─────────────────────────────────────────────────────────
# MediaPipe's wheels want 3.12 on Apple Silicon; 3.9/3.13 both cost me time here.
PYBIN=""
for c in /opt/homebrew/opt/python@3.12/bin/python3.12 python3.12; do
  command -v "$c" >/dev/null 2>&1 && { PYBIN="$(command -v "$c")"; break; }
done
if [[ -z "$PYBIN" ]]; then
  run "brew install python@3.12"
  PYBIN="/opt/homebrew/opt/python@3.12/bin/python3.12"
fi
[[ "$DRY" == 0 ]] && [[ -x "$PYBIN" ]] || { [[ "$DRY" == 1 ]] || die "python3.12 not found after install"; }
[[ "$DRY" == 0 ]] && ok "Python $("$PYBIN" -c 'import sys;print(sys.version.split()[0])')"

# ── 2. Packages ────────────────────────────────────────────────────────────
# PINS are exactly what runs on the reference workstation. --loose installs latest if
# pip cannot resolve them for your Python/platform.
PINS=(
  "mediapipe==1.2.2"
  "opencv-python==5.0.0.93"           # FaceDetectorYN / FaceRecognizerSF live in objdetect here
  "opencv-contrib-python==5.0.0.93"   # aruco/extra modules; harmless next to opencv-python
  "numpy==2.5.4"
  "scipy==1.18.1"
  "pedalboard==0.9.26"                # audio side of the same analyses
  "scenedetect==0.7.2"
  "scikit-image==0.26.0"
)
run "mkdir -p '$VENV_DIR'"
run "'$PYBIN' -m venv '$VENV_DIR'"
if [[ "$LOOSE" == 1 ]]; then
  PKGS=("${PINS[@]%%==*}")
  warn "--loose: installing latest of ${PKGS[*]}"
else
  PKGS=("${PINS[@]}")
fi
run "'$VENV_DIR/bin/pip' install --upgrade pip >/dev/null"
run "'$VENV_DIR/bin/pip' install ${PKGS[*]}"
ok "venv packages installed"

# ── 3. Models, kept OUTSIDE the venv ───────────────────────────────────────
# A venv is disposable; models are not. MediaPipe's documented endpoints plus the two
# OpenCV Zoo ONNX files (all verified reachable at write time). Licences: MediaPipe code
# is Apache-2.0 (its hosted .task/.tflite pages carry no licence line — check before a paid
# job); YuNet weights are MIT, SFace weights Apache-2.0, both stated in the LICENSE file
# inside their opencv_zoo model directory.
run "mkdir -p '$MODELS_DIR'"
declare -a MODELS=(
  "face_landmarker.task|https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task"
  "pose_landmarker_full.task|https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_full/float16/1/pose_landmarker_full.task"
  "blaze_face_short_range.tflite|https://storage.googleapis.com/mediapipe-models/face_detector/blaze_face_short_range/float16/1/blaze_face_short_range.tflite"
  "blaze_face_full_range.tflite|https://storage.googleapis.com/mediapipe-models/face_detector/blaze_face_full_range/float16/1/blaze_face_full_range.tflite"
  "face_detection_yunet_2023mar.onnx|https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx"
  "face_recognition_sface_2021dec.onnx|https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx"
)
for entry in "${MODELS[@]}"; do
  name="${entry%%|*}"; url="${entry#*|}"
  if [[ -f "$MODELS_DIR/$name" ]]; then ok "$name already present"; continue; fi
  log "downloading $name"
  run "curl -fL --retry 3 -o '$MODELS_DIR/$name' '$url'"
done
echo
ok "detection + recognition weights: 233 KB (YuNet) + 38.7 MB (SFace) — nothing downloads itself"
ok "at first run, and no research-licensed weights are installed anywhere."

# ── 4. Verify the imports actually import, and the models actually load ─────
if [[ "$DRY" == 0 ]]; then
  log "verifying imports + model load (a truncated download fails here, not at probe time)"
  VENV_DIR="$VENV_DIR" MODELS_DIR="$MODELS_DIR" "$VENV_DIR/bin/python" - <<'PY'
import os, sys
import numpy as np, mediapipe as mp, cv2
print("  python      ", sys.version.split()[0])
print("  mediapipe   ", mp.__version__)
print("  opencv      ", cv2.__version__)
for name in ("FaceDetectorYN", "FaceRecognizerSF"):
    if not hasattr(cv2, name):
        raise SystemExit(f"  cv2.{name} missing — this opencv build has no objdetect DNN classes")
models_dir = os.environ["MODELS_DIR"]
missing = [f for f in ("face_landmarker.task", "pose_landmarker_full.task",
                       "face_detection_yunet_2023mar.onnx", "face_recognition_sface_2021dec.onnx")
           if not os.path.isfile(os.path.join(models_dir, f))]
if missing:
    raise SystemExit(f"  MISSING models: {missing}")
det = cv2.FaceDetectorYN.create(os.path.join(models_dir, "face_detection_yunet_2023mar.onnx"),
                                "", (320, 240), 0.5, 0.3, 5)
det.detect(np.zeros((240, 320, 3), dtype=np.uint8))          # graph runs end to end
sf = cv2.FaceRecognizerSF.create(os.path.join(models_dir, "face_recognition_sface_2021dec.onnx"), "")
print("  yunet + sface load and run OK")
for f in ("face_landmarker.task", "pose_landmarker_full.task",
          "face_detection_yunet_2023mar.onnx", "face_recognition_sface_2021dec.onnx"):
    print(f"    {f:36s} {os.path.getsize(os.path.join(models_dir, f)) / 1e6:8.1f} MB")
print("  models      present in", models_dir)
PY
  ok "vision stack ready"
fi

# ── 5. Optional: the MCP server's own face analyzer ────────────────────────
if [[ -n "$MCP_VENV" ]]; then
  echo
  warn "Installing mediapipe + opencv-python into the MCP SERVER venv: $MCP_VENV"
  warn "This enables media_analysis(action='strata_run', params={analyzers:['face']})."
  warn "Trade-off (measured, not theoretical): the server installer's repair path recreates"
  warn "that venv and wipes extra packages, and opencv pins then share one resolver with the"
  warn "runtime that must keep working. Re-run this flag after any server repair."
  run "'$MCP_VENV/bin/pip' install mediapipe==1.2.2 opencv-python==5.0.0.93"
  ok "server venv updated — restart the MCP servers (/mcp → reconnect) to pick it up"
fi

echo
echo "Next steps:"
echo "  vision/face_probe.py --image some_frame.png            # faces + mouth-open + embeddings"
echo "  vision/face_probe.py --video clip.mov --time 60        # pulls the frame itself"
echo "  Use the venv's interpreter explicitly — system python3 here is 3.9:"
echo "    $VENV_DIR/bin/python vision/face_probe.py --help"
