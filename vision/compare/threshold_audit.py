#!/usr/bin/env python3
"""threshold_audit.py — what does lowering YuNet's score_threshold actually buy?

Counts alone can't answer that: 98 faces at 0.3 vs 89 at 0.6 could be 9 more real
faces or 9 more false positives. This answers it two ways that don't need labels:

  1. **Persistence.** Two frames a second apart of a mostly-static scene. A real face
     is still there at the same place; a hallucinated box usually is not (it depends
     on noise the encoder changed). IoU-matched across frames = persisted.
  2. **A labelled contact sheet** of the marginal boxes (found at the low threshold,
     absent at the high one), so a human — or a vision model — can just look.

  <venv python> threshold_audit.py --low 0.30 --high 0.60 \
      --frame-a runs/choir_240.png --frame-b runs/choir_241.png --out-dir runs/audit

Both frames go through the same tile grid as face_probe.py. Writes one montage PNG
plus a JSON summary. The montage is of real faces: keep it local.
"""
import argparse, json, os, sys

import cv2
import numpy as np

DET_MODEL = "face_detection_yunet_2023mar.onnx"


def detect(img, model_path, thr, tile_target=2048):
    h, w = img.shape[:2]
    cols, rows = max(1, -(-w // tile_target)), max(1, -(-h // tile_target))
    det = cv2.FaceDetectorYN.create(model_path, "", (64, 64), float(thr), 0.3, 5000)
    out = []
    for r in range(rows):
        for c in range(cols):
            x0, y0 = w * c // cols, h * r // rows
            x1, y1 = (w * (c + 1) // cols if c < cols - 1 else w,
                      h * (r + 1) // rows if r < rows - 1 else h)
            tile = np.ascontiguousarray(img[y0:y1, x0:x1])
            det.setInputSize((x1 - x0, y1 - y0))
            _, found = det.detect(tile)
            if found is None:
                continue
            for f in found:
                bx, by, bw, bh = (int(v) for v in f[0:4])
                out.append({"x": x0 + bx, "y": y0 + by, "w": bw, "h": bh, "score": float(f[14])})
    return out


def iou(a, b):
    ax2, ay2 = a["x"] + a["w"], a["y"] + a["h"]
    bx2, by2 = b["x"] + b["w"], b["y"] + b["h"]
    ix, iy = max(a["x"], b["x"]), max(a["y"], b["y"])
    jx, jy = min(ax2, bx2), min(ay2, by2)
    if jx <= ix or jy <= iy:
        return 0.0
    inter = (jx - ix) * (jy - iy)
    return inter / (a["w"] * a["h"] + b["w"] * b["h"] - inter)


def unmatched(low, high, thr_iou=0.3):
    """Boxes present at the low threshold but not at the high one (greedy IoU)."""
    pairs = sorted(((iou(a, b), i, j) for i, a in enumerate(low) for j, b in enumerate(high)
                    if iou(a, b) >= thr_iou), reverse=True)
    ui, hj = set(), set()
    for _v, i, j in pairs:
        if i in ui or j in hj:
            continue
        ui.add(i); hj.add(j)
    return [a for i, a in enumerate(low) if i not in ui]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--low", type=float, required=True)
    ap.add_argument("--high", type=float, required=True)
    ap.add_argument("--frame-a", required=True)
    ap.add_argument("--frame-b", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--models", default=os.environ.get("VISION_MODELS", os.path.expanduser("~/resolve-vision-models")))
    ap.add_argument("--max-tiles", type=int, default=60)
    args = ap.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)
    model = os.path.join(args.models, DET_MODEL)

    a = cv2.imread(args.frame_a)
    b = cv2.imread(args.frame_b)
    if a is None or b is None:
        sys.exit("cannot read one of the frames")

    low_a = detect(a, model, args.low)
    high_a = detect(a, model, args.high)
    low_b = detect(b, model, args.low)
    summary = {"frame_a": os.path.basename(args.frame_a), "frame_b": os.path.basename(args.frame_b),
               "low": args.low, "high": args.high,
               "faces_low": len(low_a), "faces_high": len(high_a), "faces_low_frame_b": len(low_b)}

    marginal = unmatched(low_a, high_a)
    summary["marginal_count"] = len(marginal)
    # persistence: does each marginal box still exist at the low threshold in frame B?
    persisted = 0
    for m in marginal:
        best = max((iou(m, o) for o in low_b), default=0.0)
        m["persisted_iou"] = round(best, 3)
        if best >= 0.3:
            persisted += 1
    summary["marginal_persisted"] = persisted
    summary["marginal_persistence"] = round(persisted / len(marginal), 3) if marginal else None

    # reference: persistence of the boxes both thresholds agree on
    agreed = [x for x in low_a if any(iou(x, y) >= 0.3 for y in high_a)]
    agreed_persist = sum(1 for x in agreed if max((iou(x, o) for o in low_b), default=0) >= 0.3)
    summary["agreed_count"] = len(agreed)
    summary["agreed_persistence"] = round(agreed_persist / len(agreed), 3) if agreed else None

    # contact sheet of the marginal boxes, biggest first, each labelled with its score
    tiles = []
    for m in sorted(marginal, key=lambda x: -x["w"] * x["h"])[: args.max_tiles]:
        fw, fh = m["w"], m["h"]
        half = 1.5 * max(fw, fh)
        cx, cy = m["x"] + fw / 2, m["y"] + fh / 2
        x0, y0 = int(max(0, cx - half)), int(max(0, cy - half))
        x1, y1 = int(min(a.shape[1], cx + half)), int(min(a.shape[0], cy + half))
        crop = a[y0:y1, x0:x1].copy()
        side = 160
        crop = cv2.resize(crop, (side, side))
        cv2.rectangle(crop, (0, 0), (side - 1, side - 1), (0, 255, 255), 2)
        cv2.putText(crop, f"{m['score']:.2f} {fw}x{fh}", (4, side - 8),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.4, (0, 255, 255), 1)
        tiles.append(crop)
    montage = None
    if tiles:
        per_row = 8
        while len(tiles) % per_row:
            blank = np.zeros((side, side, 3), dtype=np.uint8)
            tiles.append(blank)
        rows_out = [np.hstack(tiles[i:i + per_row]) for i in range(0, len(tiles), per_row)]
        montage = np.vstack(rows_out)
        path = os.path.join(args.out_dir, f"marginal_{args.low}_vs_{args.high}.png")
        cv2.imwrite(path, montage)
        summary["montage"] = path
        summary["montage_size_px"] = list(montage.shape[:2])

    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
