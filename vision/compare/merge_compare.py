#!/usr/bin/env python3
"""Merge compare_detectors.py JSON dumps: detection agreement + embedding quality.

  <venv python> merge_compare.py --in "runs/*.json" [--iou 0.3]

Reports, for every backend pair:
  - box counts, and how many boxes match at IoU >= --iou (greedy, highest IoU first)
  - unmatched-from-each counts (a detector seeing faces the other missed, and one
    inventing boxes the other does not see)
Then, if embeddings exist for a matched pair of detectors:
  - same-box distance (identity of the same crop across detectors is not comparable,
    so instead: nearest-neighbour distance distribution *within* one detector's set,
    which is a separability proxy when no identity labels exist)
Nothing here claims accuracy: with no labelled faces, agreement between independent
detectors plus a eyeball pass over disagreement crops is the honest ceiling.
"""
import argparse, glob, itertools, json, math, os, sys


def iou(a, b):
    ax1, ay1, ax2, ay2 = a["x"], a["y"], a["x"] + a["w"], a["y"] + a["h"]
    bx1, by1, bx2, by2 = b["x"], b["y"], b["x"] + b["w"], b["y"] + b["h"]
    ix, iy = max(ax1, bx1), max(ay1, by1)
    jx, jy = min(ax2, bx2), min(ay2, by2)
    if jx <= ix or jy <= iy:
        return 0.0
    inter = (jx - ix) * (jy - iy)
    return inter / ((ax2 - ax1) * (ay2 - ay1) + (bx2 - bx1) * (by2 - by1) - inter)


def greedy_match(A, B, thr):
    cand = []
    for i, a in enumerate(A):
        for j, b in enumerate(B):
            v = iou(a, b)
            if v >= thr:
                cand.append((v, i, j))
    cand.sort(reverse=True)
    ua, ub, pairs = set(), set(), []
    for v, i, j in cand:
        if i in ua or j in ub:
            continue
        ua.add(i); ub.add(j); pairs.append((i, j, v))
    return pairs, sorted(ua), sorted(ub)


def cos(a, b):
    d = math.sqrt(sum(x * x for x in a) * sum(y * y for y in b))
    if not d:
        return 0.0
    return sum(x * y for x, y in zip(a, b)) / d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="pat", required=True)
    ap.add_argument("--iou", type=float, default=0.3)
    ap.add_argument("--save-disagreements", default=None,
                    help="dir to write crops of unmatched boxes for eyeballing")
    a = ap.parse_args()

    runs = {}
    for p in sorted(glob.glob(a.pat)):
        d = json.load(open(p))
        runs[d["model"]] = d
    if len(runs) < 2:
        sys.exit(f"need >=2 runs, got {list(runs)}")

    print(f"IoU threshold {a.iou}\n")
    print(f"{'backend':38} {'faces':>6} {'detect_s':>9} {'total_s':>8} {'grid':>6} {'init_s':>7}")
    for name, d in runs.items():
        print(f"{name:38} {d['face_count']:6} {d['detect_s']:9} {d['total_s']:8} "
              f"{str(d['grid']):>6} {d['init_s']:7}")

    print("\npairwise agreement")
    for n1, n2 in itertools.combinations(runs, 2):
        A, B = runs[n1]["boxes"], runs[n2]["boxes"]
        pairs, ua, ub = greedy_match(A, B, a.iou)
        mi = sum(v for _, _, v in pairs) / len(pairs) if pairs else 0.0
        print(f"  {n1} vs {n2}: matched {len(pairs)}  "
              f"only-in-first {len(A)-len(pairs)}  only-in-second {len(B)-len(pairs)}  "
              f"mean IoU {mi:.3f}")

    # embeddings: nearest-neighbour separability proxy per detector
    for name, d in runs.items():
        emb = d.get("embeddings")
        if not emb:
            continue
        vecs = [v for v in emb.values() if v]
        if len(vecs) < 3:
            continue
        sims = []
        for i, x in enumerate(vecs):
            best = max((cos(x, y) for j, y in enumerate(vecs) if j != i), default=0.0)
            sims.append(best)
        sims.sort()
        n = len(sims)
        print(f"\n{name}: {n} embeddings — nearest-neighbour cosine "
              f"min {sims[0]:.3f} median {sims[n//2]:.3f} max {sims[-1]:.3f}")
        print(f"  (a set where the max is high contains faces that look alike to this "
              f"model; pairs above its own operating threshold are merge risks)")


if __name__ == "__main__":
    main()
