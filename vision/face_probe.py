#!/usr/bin/env python3
"""face_probe.py — one frame in, faces out: counts, mouth state, identity embeddings, JSON.

Run it with the venv built by vision/install-vision.sh (Python 3.12):
    <venv>/bin/python vision/face_probe.py --video master.mov --time 240
    <venv>/bin/python vision/face_probe.py --image frame.png --tile 4x4

Three rules that cost real time to learn, all baked into the defaults:

1. **No detector here finds faces on a downscaled wide shot.** Feeding MediaPipe a resized
   master returns zero — measured on 8128x4288 frames with 90+ faces present: the landmarker
   returned 0 at a 1600 px cap *and* at a 4032 px cap, in under 1 ms. That's because its
   internal face detector runs at a fixed input size, so what matters is the face's **share
   of the frame**, not the frame's pixel count. A 95 px face in an 8128 px frame is ~1.2% of
   the width and simply isn't there after that resize. A whole-frame (untiled) YuNet call is
   worse than returning nothing: it reported **one box covering the entire image at score 0**.

2. **So work at native resolution, in two stages.** OpenCV YuNet scans native-resolution
   *tiles* (default grid sized so each tile is ~2048 px or smaller, which is also its comfort
   zone — the documented working range is 10x10 to 300x300 px faces, exactly where risers in
   a choir sit). Then MediaPipe lands landmarks on a **native crop around each detected
   face** (default 1.6x margin, num_faces=1). Measured: 0 faces whole-frame, 6/6 on crops,
   ~3.5 ms per face.

3. **MediaPipe 1.x removed the legacy `mp.solutions.*` namespaces.** Use the Tasks API:
   `FaceLandmarker.create_from_options` (not create_with_options), the model goes in
   `base_options=BaseOptions(model_asset_path=...)`, the knobs are
   `min_face_detection_confidence` / `min_face_presence_confidence` (there is no
   `min_presence_confidence` on FaceLandmarkerOptions — that one is on FaceDetector), and
   an OpenCV array must be wrapped as `mp.Image(image_format=mp.ImageFormat.SRGB,
   data=rgb)` — a bare ndarray raises.

Why both libraries: OpenCV carries detection and 128-d SFace identity embeddings but has no
mouth model; MediaPipe FaceLandmarker supplies 478 landmarks plus 52 ARKit blendshapes.
Neither alone does both jobs. On one 8.1K choir frame the two together land 90 faces in 0.29 s
(0.96 s with embeddings, 0.0 s model init) and put landmarks on 83 of them. SFace at its own
0.363 cosine threshold measured 1.1% same-person splits and 2.0% wrong merges on ~55 px faces —
so a distinct-people count is an estimate, and `--align` in compare/compare_detectors.py shows
how much worse it gets if you feed the model unaligned crops.

**Use `jawOpen`, not a lip-gap ratio, for "is the mouth open".** With
`output_face_blendshapes=True` you get named blendshapes. On a choir recording the two
signals disagree exactly where it matters: a singer holding a rounded vowel had
`jawOpen 0.43` while my geometric inner-lip gap read 0.02 — the mouth is open, puckered,
and a vertical-gap heuristic calls it closed (`mouthPucker 0.998` confirms the shape).
Ranges measured on one choral recording (n=1 session, faces ~70-95 px): jawOpen 0.24-0.73
while singing, <=0.03 at rest. Calibrate the threshold on your own footage.

Low counts are usually the shot, not the tool: a wide auditorium frame returned 3 faces
because the audience was facing away and the only people on stage were in profile.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time

import cv2
import numpy as np
import mediapipe as mp

try:  # OpenCV prints "Targets are not supported by the new graph engine" on every model load.
      # OpenCV 5 moved the logger: cv2.setLogLevel is gone, cv2.utils.logging.setLogLevel is it.
    cv2.utils.logging.setLogLevel(cv2.utils.logging.LOG_LEVEL_ERROR)
except AttributeError:
    try:
        cv2.setLogLevel(1)  # pre-5 builds: 1 = errors and above
    except AttributeError:
        pass
from mediapipe.tasks import python as mp_tasks
from mediapipe.tasks.python import vision as mp_vision

# FaceDetectorYN / FaceRecognizerSF ship inside opencv (contrib) >= 4.8, and OpenCV parses
# their ONNX graphs with its own bundled DNN reader — no extra runtime package anywhere.
try:
    _DETECTOR = cv2.FaceDetectorYN
    _RECOGNIZER = cv2.FaceRecognizerSF
except AttributeError as exc:  # noqa: BLE001
    sys.exit(f"cv2.FaceDetectorYN/FaceRecognizerSF missing ({exc}); "
             "install opencv-contrib-python>=4.8 — see vision/install-vision.sh")

MOUTH_TOP, MOUTH_BOTTOM = 13, 14  # inner-lip indices in the 478-point face mesh
TILE_TARGET_PX = 2048             # keeps each tile in YuNet's documented 10x10-300x300 px range
DET_MODEL = "face_detection_yunet_2023mar.onnx"
RECOG_MODEL = "face_recognition_sface_2021dec.onnx"


def load_frame(args) -> np.ndarray:
    if args.image:
        frame = cv2.imread(args.image, cv2.IMREAD_COLOR)
        if frame is None:
            sys.exit(f"could not read image: {args.image}")
        return frame
    cap = cv2.VideoCapture(args.video)
    if not cap.isOpened():
        sys.exit(f"could not open video: {args.video}")
    if args.frame is not None:
        cap.set(cv2.CAP_PROP_POS_FRAMES, args.frame)
    else:
        cap.set(cv2.CAP_PROP_POS_MSEC, float(args.time) * 1000.0)
    ok, frame = cap.read()
    cap.release()
    if not ok or frame is None:
        sys.exit("that --time/--frame produced no image")
    return frame


def auto_grid(w: int, h: int) -> tuple[int, int]:
    return max(1, math.ceil(w / TILE_TARGET_PX)), max(1, math.ceil(h / TILE_TARGET_PX))


def tiles(h: int, w: int, cols: int, rows: int):
    for r in range(rows):
        for c in range(cols):
            y0, y1 = h * r // rows, h * (r + 1) // rows
            x0, x1 = w * c // cols, w * (c + 1) // cols
            if y1 - y0 < 64 or x1 - x0 < 64:
                continue
            yield x0, y0, x1, y1


def yunet_faces(frame, tile_grid, det_path, recog_path, score_threshold):
    """Native-resolution tile pass; returns merged faces with full-frame bboxes + SFace vectors.

    YuNet rows are [x, y, w, h, lx1, ly1 ... lx5, ly5, score] — a bbox **plus the five
    landmarks** in tile-local coordinates. Those landmarks are not a bonus: `alignCrop` uses
    them to build the aligned 112 px crop SFace was trained on. Measured on real footage, the
    same model fed a plain bbox crop instead: same-person cosine median 0.901 -> 0.249, and the
    share of the same person's faces judged different people 1.1% -> 63.2% (AUC 0.999 -> 0.769).
    """
    det = _DETECTOR.create(det_path, "", (64, 64), float(score_threshold), 0.3, 5000)
    sf = _RECOGNIZER.create(recog_path, "") if recog_path else None
    h, w = frame.shape[:2]
    cols, rows = tile_grid
    found, raw, align_fails, t0 = [], 0, 0, time.perf_counter()
    for x0, y0, x1, y1 in tiles(h, w, cols, rows):
        # contiguous copy, not the slice view: a view shares the parent's row stride, and
        # alignCrop reads pixels out of whatever image object it is handed
        tile = np.ascontiguousarray(frame[y0:y1, x0:x1])
        det.setInputSize((x1 - x0, y1 - y0))  # per-tile input size; YuNet takes any size
        _, rows_out = det.detect(tile)
        if rows_out is None:
            continue
        for r in rows_out:
            raw += 1
            bx, by, bw, bh = (int(v) for v in r[0:4])
            vec = None
            if sf is not None:
                try:
                    vec = sf.feature(sf.alignCrop(tile, r)).flatten()
                except cv2.error:
                    align_fails += 1
            found.append({
                # tile-local bbox -> full-frame bbox
                "bbox": [x0 + bx, y0 + by, x0 + bx + bw, y0 + by + bh],
                "det_score": round(float(r[14]), 4),
                "embedding_dim": int(vec.size) if vec is not None else 0,
                "_embedding": vec,
            })
    elapsed = time.perf_counter() - t0

    # Tiles overlap at their borders, so the same face can be reported twice. Keep the
    # highest-scoring copy of any cluster whose centres fall within 40% of face size.
    merged = []
    for face in sorted(found, key=lambda f: -f["det_score"]):
        ax0, ay0, ax1, ay1 = face["bbox"]
        acx, acy = (ax0 + ax1) / 2.0, (ay0 + ay1) / 2.0
        adiag = ((ax1 - ax0) + (ay1 - ay0)) / 2.0
        dup = False
        for kept in merged:
            kx0, ky0, kx1, ky1 = kept["bbox"]
            kcx, kcy = (kx0 + kx1) / 2.0, (ky0 + ky1) / 2.0
            kdiag = ((kx1 - kx0) + (ky1 - ky0)) / 2.0
            if (acx - kcx) ** 2 + (acy - kcy) ** 2 < (0.4 * max(adiag, kdiag)) ** 2:
                dup = True
                break
        if not dup:
            merged.append(face)
    if align_fails:
        print(f"NOTE: {align_fails} face(s) produced no embedding (alignCrop failed)", file=sys.stderr)
    return merged, raw, elapsed


def landmarker(model_path, max_faces=1):
    return mp_vision.FaceLandmarker.create_from_options(mp_vision.FaceLandmarkerOptions(
        base_options=mp_tasks.BaseOptions(model_asset_path=model_path),
        running_mode=mp_vision.RunningMode.IMAGE,
        num_faces=int(max_faces),
        min_face_detection_confidence=0.3,
        min_face_presence_confidence=0.3,
        output_face_blendshapes=True,
    ))


def measure_mouths(frame, faces, model_path, margin, max_crops):
    """Stage 2: MediaPipe on native-resolution crops around each detection."""
    h, w = frame.shape[:2]
    lm = landmarker(model_path)
    order = sorted(faces, key=lambda f: -((f["bbox"][2] - f["bbox"][0]) * (f["bbox"][3] - f["bbox"][1])))
    if max_crops:
        order = order[:max_crops]
    tried, hits, t0 = 0, 0, time.perf_counter()
    for face in order:
        x0, y0, x1, y1 = face["bbox"]
        fw, fh = x1 - x0, y1 - y0
        half = (float(margin) / 2.0) * max(fw, fh)
        cx0, cy0 = int(max(0, (x0 + x1) / 2 - half)), int(max(0, (y0 + y1) / 2 - half))
        cx1, cy1 = int(min(w, (x0 + x1) / 2 + half)), int(min(h, (y0 + y1) / 2 + half))
        if cx1 - cx0 < 48 or cy1 - cy0 < 48:  # too small for the landmark model to be worth a call
            face["mouth"] = {"skipped": "crop below 48 px"}
            continue
        tried += 1
        crop = frame[cy0:cy1, cx0:cx1]
        img = mp.Image(image_format=mp.ImageFormat.SRGB, data=cv2.cvtColor(crop, cv2.COLOR_BGR2RGB))
        res = lm.detect(img)
        if not res.face_landmarks:
            face["mouth"] = {"landmarks": 0}
            continue
        hits += 1
        lms = res.face_landmarks[0]
        ys = [p.y for p in lms]
        xs = [p.x for p in lms]
        face_h = max(1e-6, max(ys) - min(ys))
        shapes = {c.category_name: round(float(c.score), 3) for c in res.face_blendshapes[0]} \
            if res.face_blendshapes else {}
        face["mouth"] = {
            "landmarks": len(lms),
            "jawOpen": shapes.get("jawOpen"),
            "mouthPucker": shapes.get("mouthPucker"),
            "blendshapes": len(shapes),
            # kept only as a cross-check; it under-reads puckered-open mouths (see header)
            "geo_open_ratio": round((lms[MOUTH_BOTTOM].y - lms[MOUTH_TOP].y) / face_h, 4),
        }
    return tried, hits, time.perf_counter() - t0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--image", help="path to a single frame")
    src.add_argument("--video", help="path to a video; pair with --time or --frame")
    ap.add_argument("--time", type=float, default=0.0, help="seconds into --video")
    ap.add_argument("--frame", type=int, help="exact frame index in --video (wins over --time)")
    ap.add_argument("--tile", default="auto", help="detection tile grid WxH, or 'auto' (each tile <= %d px)" % TILE_TARGET_PX)
    ap.add_argument("--score-threshold", type=float, default=0.5,
                    help="YuNet face score. Measured on one 8.1K choir frame (faces 43-100 px): "
                         "0.90 -> 56 faces, 0.75 -> 86, 0.60 -> 89, 0.50 -> 90, 0.45 -> 93, "
                         "0.30 -> 98. The OpenCV Zoo demo defaults to 0.9, which throws away a "
                         "third of the faces here; below ~0.45 the extra boxes are mostly noise "
                         "(of the 9 boxes 0.30 adds over 0.60, only 4 were still there a second "
                         "later, and 3 were legs, a music folder, and a three-torso group box). "
                         "0.50-0.60 is the measured band; recalibrate on your own footage.")
    ap.add_argument("--no-embeddings", action="store_true",
                    help="skip the SFace recognition leg (counts only — also the licence-cleanest "
                         "option if you never distribute vectors)")
    ap.add_argument("--models", default=os.environ.get("VISION_MODELS", os.path.expanduser("~/resolve-vision-models")),
                    help="directory holding face_landmarker.task + the two OpenCV Zoo .onnx files")
    ap.add_argument("--crop-margin", type=float, default=1.6, help="native crop as a multiple of face size")
    ap.add_argument("--max-crops", type=int, default=0, help="cap stage-2 crops (0 = every detected face)")
    ap.add_argument("--jawopen-threshold", type=float, default=0.20,
                    help="jawOpen above which a face is flagged as a vocal candidate (heuristic — calibrate)")
    ap.add_argument("--save-embeddings", help="write face bboxes + SFace vectors here (.npz), "
                                             "L2-normalised so a dot product is a cosine. "
                                             "IDENTITY DATA: keep it local, never publish it.")
    ap.add_argument("--json-out", help="also write the JSON here")
    args = ap.parse_args()

    frame = load_frame(args)
    h, w = frame.shape[:2]
    if args.tile.lower() == "auto":
        cols, rows = auto_grid(w, h)
    else:
        try:
            cols, rows = (int(v) for v in args.tile.lower().split("x"))
        except ValueError:
            sys.exit("--tile wants WxH (e.g. 4x4) or 'auto'")

    def model(name):
        path = os.path.join(args.models, name)
        if not os.path.isfile(path):
            sys.exit(f"missing {path} — run vision/install-vision.sh --models {args.models}")
        return path

    det_path = model(DET_MODEL)
    recog_path = None if args.no_embeddings else model(RECOG_MODEL)
    faces, raw, det_s = yunet_faces(frame, (cols, rows), det_path, recog_path, args.score_threshold)

    landmark_path = model("face_landmarker.task")
    tried, hits, mp_s = measure_mouths(frame, faces, landmark_path, args.crop_margin, args.max_crops)

    for f in faces:
        f["face_w_px"] = f["bbox"][2] - f["bbox"][0]
        f["face_h_px"] = f["bbox"][3] - f["bbox"][1]
    vocal = [f for f in faces if (f.get("mouth") or {}).get("jawOpen") is not None
             and f["mouth"]["jawOpen"] >= args.jawopen_threshold]

    result = {
        "source": {"image": args.image, "video": args.video,
                   "time_s": args.time, "frame": args.frame, "width": w, "height": h},
        "detection": {"model": DET_MODEL, "recognizer": RECOG_MODEL if recog_path else None,
                      "embedding_dim": (faces[0]["embedding_dim"] if faces else 0),
                      "score_threshold": args.score_threshold,
                      "tile_grid": f"{cols}x{rows}", "tiles": cols * rows,
                      "tile_target_px": TILE_TARGET_PX, "faces_raw": raw, "faces_merged": len(faces),
                      "wall_s": round(det_s, 3)},
        "mediapipe": {"model": landmark_path, "crops_tried": tried, "landmarks_found": hits,
                      "crop_margin": args.crop_margin, "wall_s": round(mp_s, 3),
                      "note": "whole-frame detection was 0 at 1600 and 4032 px caps on this "
                              "content; stage 2 runs on native crops for that reason"},
        "faces": [{k: v for k, v in f.items() if not k.startswith("_")} for f in faces],
        "interpretation": {
            "jawopen_threshold": args.jawopen_threshold,
            "vocal_candidates": len(vocal),
            "mouth_signal": "jawOpen (ARKit blendshape). geo_open_ratio is a vertical-gap "
                            "heuristic that misses puckered-open mouths; compare mouthPucker.",
            "identity_signal": "SFace 128-d cosine; the model's published same-person threshold is "
                               "0.363. On ~55 px faces it measured 1.1% same-person splits and "
                               "2.0% wrong merges (AUC 0.999) — treat a distinct-people count as "
                               "an estimate, and re-measure on your own footage.",
            "caveat": "thresholds measured on one choral session (n=1, faces ~70-95 px). "
                      "MediaPipe's Pose Landmarker detects at most 3 people per call, so "
                      "never read group counts from pose.",
        },
    }

    if args.save_embeddings:
        vecs, meta = [], []
        for i, f in enumerate(faces):
            if f.get("_embedding") is None:
                continue
            v = np.asarray(f["_embedding"], dtype=np.float32)
            # SFace does NOT hand back unit-normed vectors (measured norms ~10-27), so a raw
            # dot product is not a cosine and the published 0.363 threshold would mean nothing.
            norm = float(np.linalg.norm(v))
            if norm:
                v = v / norm
            vecs.append(v)
            meta.append({"i": i, "bbox": f["bbox"], "det_score": f["det_score"],
                         "raw_norm": norm})
        np.savez_compressed(args.save_embeddings,
                            embeddings=np.asarray(vecs, dtype=np.float32),
                            meta=json.dumps(meta),
                            normalised=np.asarray([True]),
                            cosine_threshold=np.asarray([0.363], dtype=np.float32))
        print(f"WROTE {len(vecs)} {faces[0]['embedding_dim']}-d L2-normalised face vectors to "
              f"{args.save_embeddings} (cosine >= 0.363 = same person) — identity data, "
              f"keep it local.", file=sys.stderr)

    text = json.dumps(result, indent=2)
    print(text)
    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
