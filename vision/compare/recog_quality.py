#!/usr/bin/env python3
"""Label-free recognition quality: same face across two frames vs different faces.

Two frames 1 s apart of a mostly-static choir. A face detected in both frames at the
same position is treated as the SAME person (positives); detections at clearly
different positions are DIFFERENT people (negatives). No identity labels exist, so
this measures separability, not accuracy — and it is honest about that.

  <venv python> recog_quality.py --a runs/yunet_240.json --b runs/yunet_241.json \
      --threshold 0.363 --label "YuNet+SFace"

Similarity is cosine throughout, and vectors are normalised first: OpenCV's FaceRecognizerSF
returns raw activations (measured norms ~10-27), so its published 0.363 same-person threshold
means nothing on unnormalised vectors. (OpenCV's own match(f1, f2, 0) reports the same cosine;
dis_type 1 is L2 distance instead, where 0.0 is identical.)
"""
import argparse, json, math, sys


def cos(a, b):
    # neither stack hands back unit-normed vectors on this build (measured norms
    # ~10-27), so normalise here or the published thresholds mean nothing
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if not na or not nb:
        return 0.0
    return sum(x * y for x, y in zip(a, b)) / (na * nb)


def iou(a, b):
    ax2, ay2, bx2, by2 = a["x"] + a["w"], a["y"] + a["h"], b["x"] + b["w"], b["y"] + b["h"]
    ix, iy = max(a["x"], b["x"]), max(a["y"], b["y"])
    jx, jy = min(ax2, bx2), min(ay2, by2)
    if jx <= ix or jy <= iy:
        return 0.0
    inter = (jx - ix) * (jy - iy)
    return inter / (a["w"] * a["h"] + b["w"] * b["h"] - inter)


def load(p):
    d = json.load(open(p))
    emb = d.get("embeddings") or {}
    out = []
    for bx in d["boxes"]:
        k = f"{bx['x']}_{bx['y']}"
        v = emb.get(k)
        if v:
            out.append((bx, v))
    return d["model"], out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", required=True)
    ap.add_argument("--b", required=True)
    ap.add_argument("--threshold", type=float, required=True,
                    help="the model's own same-person cosine threshold")
    ap.add_argument("--label", required=True)
    ap.add_argument("--match-iou", type=float, default=0.3)
    a = ap.parse_args()

    m1, A = load(a.a)
    m2, B = load(a.b)
    cand = sorted(((iou(x[0], y[0]), i, j) for i, x in enumerate(A) for j, y in enumerate(B)
                   if iou(x[0], y[0]) >= a.match_iou), reverse=True)
    ui, uj, pos = set(), set(), []
    for _v, i, j in cand:
        if i in ui or j in uj:
            continue
        ui.add(i); uj.add(j)
        pos.append(cos(A[i][1], B[j][1]))
    # negatives: same-frame pairs far apart (IoU < 0.05) — different people by position
    neg = []
    for src in (A, B):
        for i in range(len(src)):
            for j in range(i + 1, len(src)):
                if iou(src[i][0], src[j][0]) < 0.05:
                    neg.append(cos(src[i][1], src[j][1]))
    if not pos or len(neg) < 10:
        sys.exit(f"not enough pairs: positives={len(pos)} negatives={len(neg)}")

    pos.sort(); neg.sort()
    # Mann-Whitney U -> AUC
    wins = sum(1 for p in pos for n in neg if p > n) + 0.5 * sum(1 for p in pos for n in neg if p == n)
    auc = wins / (len(pos) * len(neg))
    thr = a.threshold
    fn = sum(1 for p in pos if p < thr) / len(pos)          # same person judged different
    fp = sum(1 for n in neg if n >= thr) / len(neg)         # different people judged same
    print(f"{a.label} ({m1})")
    print(f"  same-face pairs (IoU-matched across 1 s): {len(pos)}  "
          f"cos min {pos[0]:.3f} median {pos[len(pos)//2]:.3f} max {pos[-1]:.3f}")
    print(f"  different-face pairs (same frame, apart): {len(neg)}  "
          f"cos median {neg[len(neg)//2]:.3f} p95 {neg[int(0.95*len(neg))]:.3f} max {neg[-1]:.3f}")
    print(f"  at its own threshold {thr}: splits same-person {fn:.1%}, "
          f"merges different people {fp:.1%}   AUC {auc:.3f}")
    print("  (positives are position-matched across frames, so a stationary neighbour "
          "swap could pollute them; that would lower AUC, not inflate it)")


if __name__ == "__main__":
    main()
