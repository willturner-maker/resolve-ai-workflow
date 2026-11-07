#!/usr/bin/env python3
"""Detector/recognition comparison on the same native-resolution frames.

Runs ONE backend per process and dumps normalised JSON, so merge_compare.py can
IoU-match the runs against each other. This is how a candidate detector gets
judged before it is allowed anywhere near the pipeline: same frames, same tile
grid, box-for-box agreement rather than a face count.

Usage:
  <venv python> compare_detectors.py --backend yunet  --frame FRAME.png --out OUT.json --embed
  <venv python> compare_detectors.py --backend mediapipe --frame FRAME.png --out OUT.json
  <venv python> compare_detectors.py --backend yunet --frame F.png --out O.json --embed \
      --recognizer face_recognition_sface_2021dec_int8.onnx      # quantisation A/B

Backends:
  yunet      OpenCV FaceDetectorYN, + SFace with --embed     (the live stack; no extra package)
  mediapipe  MediaPipe Tasks FaceDetector over tiles        (needs mediapipe)

A new detector is one function: read the frame, walk `tiles()`, emit boxes in
full-frame coordinates, and register it in BACKENDS.

Models are found via --models DIR, else $VISION_MODELS, else ./models next to this script.

Why native tiles: every detector here is fixed-input-ish; a face that is ~1% of
the frame width disappears after a downscale (measured three ways). Tiles are
cut at native resolution, exactly as vision/face_probe.py does.
"""
import argparse, json, os, sys, time

TILE_TARGET_PX = 2048          # same auto-sizing rule as face_probe.py
MARGIN_TILES = (4, 3)          # the published "auto" grid on this footage


def tiles(shape, gx, gy):
    H, W = shape[:2]
    for j in range(gy):
        for i in range(gx):
            x0, y0 = i * W // gx, j * H // gy
            x1, y1 = (i + 1) * W // gx if i < gx - 1 else W, (j + 1) * H // gy if j < gy - 1 else H
            yield i, j, x0, y0, x1, y1


def auto_grid(shape):
    H, W = shape[:2]
    gx = max(1, -(-W // TILE_TARGET_PX))
    gy = max(1, -(-H // TILE_TARGET_PX))
    return gx, gy


def models_dir(opts):
    """--models, else $VISION_MODELS (the same dir face_probe.py uses), else ./models."""
    base = opts.models or os.environ.get("VISION_MODELS") \
        or os.path.join(os.path.dirname(os.path.abspath(__file__)), "models")
    return base


def run_yunet(img, opts):
    import cv2
    base = models_dir(opts)
    model = opts.model or os.path.join(base, "face_detection_yunet_2023mar.onnx")
    t0 = time.time()
    det = cv2.FaceDetectorYN.create(model, "", (64, 64), opts.score_thresh, 0.3, 5000)
    init = time.time() - t0
    gx, gy = auto_grid(img.shape) if opts.tile == "auto" else tuple(int(v) for v in opts.tile.split("x"))
    boxes, tsum, esum = [], 0.0, 0.0
    feats, errs = {}, []
    # --recognizer swaps the SFace build (fp32 vs the Zoo int8 builds) while holding the
    # detector fixed, so a quantisation A/B is one flag, not a second harness.
    recog = opts.recognizer or "face_recognition_sface_2021dec.onnx"
    recog_path = recog if os.path.isabs(recog) else os.path.join(base, recog)
    sf = cv2.FaceRecognizerSF.create(recog_path, "") if opts.embed else None
    import numpy as np
    for i, j, x0, y0, x1, y1 in tiles(img.shape, gx, gy):
        # contiguous copy: a slice view shares the full row stride, and alignCrop
        # reads pixels from whatever image it is handed
        tile_img = np.ascontiguousarray(img[y0:y1, x0:x1])
        det.setInputSize((x1 - x0, y1 - y0))
        t0 = time.time()
        _ok, faces = det.detect(tile_img)
        tsum += time.time() - t0
        if faces is None:
            continue
        for f in faces:
            bx, by, bw, bh = (float(f[0]), float(f[1]), float(f[2]), float(f[3]))
            key = f"{x0 + int(bx)}_{y0 + int(by)}"
            boxes.append({"x": x0 + int(bx), "y": y0 + int(by), "w": int(bw), "h": int(bh),
                          "score": float(f[14]), "tile": [i, j]})
            if sf is not None:
                # alignCrop is the correct SFace input: it uses the detector's 5
                # landmarks (row cols 5..14) to produce the aligned 112px crop the
                # model was trained on. --align bbox is the A/B control that measures
                # how much that matters (it feeds a plain bbox crop instead).
                tE = time.time()
                try:
                    if opts.align == "bbox":
                        bx, by = int(float(f[0])), int(float(f[1]))
                        bw, bh = int(float(f[2])), int(float(f[3]))
                        x0, y0 = max(0, bx), max(0, by)
                        x1, y1 = min(tile_img.shape[1], bx + bw), min(tile_img.shape[0], by + bh)
                        patch = cv2.resize(tile_img[y0:y1, x0:x1], (112, 112))
                        vec = sf.feature(patch)
                    else:
                        vec = sf.feature(sf.alignCrop(tile_img, f))
                    esum += time.time() - tE
                    feats[key] = [float(v) for v in vec.flatten()]
                except Exception as e:
                    feats[key] = None
                    errs.append(f"{opts.align}: {type(e).__name__}: {str(e)[:80]}")
    label = "opencv YuNet"
    if opts.embed:
        label += f" + SFace({os.path.basename(recog_path)})"
    return {"model": label, "recognizer": os.path.basename(recog_path),
            "init_s": round(init, 2), "grid": [gx, gy],
            "detect_s": round(tsum, 3),
            "embed_s": round(esum, 3) if opts.embed else None,
            "embedded": sum(1 for v in feats.values() if v) if opts.embed else None,
            "boxes": boxes, "embeddings": feats if opts.embed else None,
            "errors": errs[:8], "error_count": len(errs)}


def run_mediapipe(img, opts):
    import mediapipe as mp
    import numpy as np
    base = models_dir(opts)
    # full_range is what this workstation has (install-vision.sh fetches it);
    # short_range would be the wrong test — it is trained for <=2 m selfie distances
    opts_path = opts.model or os.path.join(base, "blaze_face_full_range.tflite")
    t0 = time.time()
    det = mp.tasks.vision.FaceDetector.create_from_options(
        mp.tasks.vision.FaceDetectorOptions(
            base_options=mp.tasks.BaseOptions(model_asset_path=opts_path),
            min_detection_confidence=opts.score_thresh))
    init = time.time() - t0
    gx, gy = auto_grid(img.shape) if opts.tile == "auto" else tuple(int(v) for v in opts.tile.split("x"))
    boxes, tsum = [], 0.0
    for i, j, x0, y0, x1, y1 in tiles(img.shape, gx, gy):
        tile = img[y0:y1, x0:x1]
        mimg = mp.Image(image_format=mp.ImageFormat.SRGB, data=np.ascontiguousarray(tile[..., ::-1]))
        t0 = time.time()
        res = det.detect(mimg)
        tsum += time.time() - t0
        for d in res.detections:
            b = d.bounding_box
            boxes.append({"x": x0 + b.origin_x, "y": y0 + b.origin_y, "w": b.width, "h": b.height,
                          "score": float(d.categories[0].score), "tile": [i, j]})
    return {"model": "mediapipe blaze_face_short_range", "init_s": round(init, 2),
            "grid": [gx, gy], "detect_s": round(tsum, 3), "boxes": boxes, "embeddings": None}


BACKENDS = {"yunet": run_yunet, "mediapipe": run_mediapipe}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", required=True, choices=sorted(BACKENDS))
    ap.add_argument("--frame", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--tile", default="auto", help="'auto' or gx*gy, e.g. 4x3")
    ap.add_argument("--score-thresh", type=float, default=0.5)
    ap.add_argument("--embed", action="store_true")
    ap.add_argument("--align", choices=("crop", "bbox"), default="crop",
                    help="SFace input: alignCrop (the correct one) or a plain bbox crop "
                         "(the A/B control that measures how much alignment matters)")
    ap.add_argument("--model", default=None)
    ap.add_argument("--recognizer", default=None,
                    help="SFace build to embed with (file in --models, or a path). "
                         "The Zoo int8/int8bq builds let you A/B quantisation against fp32.")
    ap.add_argument("--models", default=None,
                    help="directory holding the .onnx/.tflite files (default: $VISION_MODELS, "
                         "then ./models next to this script)")
    opts = ap.parse_args()

    import cv2
    img = cv2.imread(opts.frame)
    if img is None:
        sys.exit(f"cannot read {opts.frame}")
    t0 = time.time()
    out = BACKENDS[opts.backend](img, opts)
    out.update({"frame": os.path.basename(opts.frame), "frame_size": list(img.shape[:2]),
                "total_s": round(time.time() - t0, 3), "face_count": len(out["boxes"]),
                "score_thresh": opts.score_thresh, "python": sys.version.split()[0]})
    with open(opts.out, "w") as f:
        json.dump(out, f)
    emb = f", embed {out['embed_s']}s ({out['embedded']} vectors)" if opts.embed else ""
    print(f"{opts.backend}: {out['face_count']} faces, detect {out['detect_s']}s{emb}, "
          f"total {out['total_s']}s, grid {out['grid']}, init {out['init_s']}s -> {opts.out}")


if __name__ == "__main__":
    main()
