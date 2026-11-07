#!/usr/bin/env python3
"""Would a face-image-quality model (OpenCV Zoo eDifFIQA) buy this pipeline anything?

Two label-free questions, on the same native tiles face_probe.py walks:

1. **False-positive filter.** YuNet at a low score threshold returns real faces plus
   junk (legs, folders, torso blobs). Does the quality score separate the boxes YuNet
   is already confident about from the marginal ones, and would a quality cut keep the
   faces it was already right about? A bigger count is not more faces, and a quality
   score that only tracks detection confidence adds nothing.
2. **Reliability signal.** For a face present in two frames 1 s apart, does its quality
   score predict how stable its SFace embedding is (same-face cosine)? If it correlates,
   it can *gate* the identity pass (skip embeddings on junk crops) rather than sit
   beside it as a second opinion.

Both legs are timed: a filter that costs more than the thing it filters is not a win.
Alignment follows the Zoo demo (estimateAffinePartial2D onto the standard 5-point
template, 112x112, RGB, (x/255-0.5)/0.5) so scores mean what the model card says.

  <venv python> quality_filter.py --frame-a A.png --frame-b B.png \
      --models DIR --low 0.30 --core 0.60 --out Q.json
"""
import argparse, json, math, os, sys, time

REFERENCE_FACIAL_POINTS = [
    [38.2946, 51.6963], [73.5318, 51.5014], [56.0252, 71.7366],
    [41.5493, 92.3655], [70.729904, 92.2041]]
TILE_TARGET_PX = 2048


def tiles(shape, gx, gy):
    H, W = shape[:2]
    for j in range(gy):
        for i in range(gx):
            x0, y0 = i * W // gx, j * H // gy
            x1, y1 = (i + 1) * W // gx if i < gx - 1 else W, (j + 1) * H // gy if j < gy - 1 else H
            yield i, j, x0, y0, x1, y1


def auto_grid(shape):
    H, W = shape[:2]
    return max(1, -(-W // TILE_TARGET_PX)), max(1, -(-H // TILE_TARGET_PX))


def align_112(img, row):
    """Zoo demo alignment: 5 landmarks -> standard template -> 112x112 warp."""
    import cv2, numpy as np
    src = np.float32(row[4:14]).reshape(5, 2)
    tfm, _ = cv2.estimateAffinePartial2D(src, np.float32(REFERENCE_FACIAL_POINTS), method=cv2.LMEDS)
    return cv2.warpAffine(img, tfm, (112, 112))


def score(net, face_bgr):
    import cv2, numpy as np
    rgb = cv2.cvtColor(face_bgr, cv2.COLOR_BGR2RGB)
    blob = np.moveaxis((((rgb / 255.0) - 0.5) / 0.5)[None, ...], -1, 1).astype(np.float32)
    net.setInput(blob)
    return float(np.squeeze(net.forward()))


def iou(a, b):
    ax2, ay2, bx2, by2 = a["x"] + a["w"], a["y"] + a["h"], b["x"] + b["w"], b["y"] + b["h"]
    ix, iy = max(a["x"], b["x"]), max(a["y"], b["y"])
    jx, jy = min(ax2, bx2), min(ay2, by2)
    if jx <= ix or jy <= iy:
        return 0.0
    inter = (jx - ix) * (jy - iy)
    return inter / (a["w"] * a["h"] + b["w"] * b["h"] - inter)


def quartiles(vals):
    if not vals:
        return None
    v = sorted(vals)
    return {"n": len(v), "min": round(v[0], 3), "p25": round(v[len(v) // 4], 3),
            "median": round(v[len(v) // 2], 3), "p75": round(v[3 * len(v) // 4], 3),
            "max": round(v[-1], 3)}


def auc(high, low):
    """P(random high > random low) — Mann-Whitney, no distribution assumed."""
    if not high or not low:
        return None
    wins = sum(1 for h in high for l in low if h > l) + 0.5 * sum(1 for h in high for l in low if h == l)
    return wins / (len(high) * len(low))


def scan(img, opts, det, sf, net):
    """Detect at --low on native tiles; per face: quality score + aligned crop + embedding."""
    import cv2, numpy as np
    gx, gy = auto_grid(img.shape) if opts.tile == "auto" else tuple(int(v) for v in opts.tile.split("x"))
    qsum, esum, dsum = 0.0, 0.0, 0.0
    out = []
    for i, j, x0, y0, x1, y1 in tiles(img.shape, gx, gy):
        tile = np.ascontiguousarray(img[y0:y1, x0:x1])
        det.setInputSize((x1 - x0, y1 - y0))
        t0 = time.time()
        _ok, faces = det.detect(tile)
        dsum += time.time() - t0
        if faces is None:
            continue
        for f in faces:
            rec = {"x": x0 + int(f[0]), "y": y0 + int(f[1]), "w": int(f[2]), "h": int(f[3]),
                   "score": round(float(f[14]), 4)}
            if net is not None:
                t1 = time.time()
                try:
                    rec["quality"] = round(score(net, align_112(tile, f)), 4)
                except Exception as e:
                    rec["quality"] = None
                    rec["q_err"] = f"{type(e).__name__}: {str(e)[:70]}"
                qsum += time.time() - t1
            if sf is not None:
                t1 = time.time()
                try:
                    v = sf.feature(sf.alignCrop(tile, f)).flatten()
                    n = float(np.linalg.norm(v))
                    rec["embedding"] = [float(x) / n for x in v] if n else None
                except Exception:
                    rec["embedding"] = None
                esum += time.time() - t1
            out.append(rec)
    return out, {"detect_s": round(dsum, 3), "quality_s": round(qsum, 3),
                 "embed_s": round(esum, 3), "grid": [gx, gy]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frame-a", required=True)
    ap.add_argument("--frame-b", default=None, help="second frame ~1 s apart, for the "
                    "embedding-stability question")
    ap.add_argument("--models", default=None, help="dir holding yunet/sface/ediffiqa .onnx "
                    "(default: $VISION_MODELS)")
    ap.add_argument("--quality-model", default="ediffiqa_tiny_jun2024.onnx")
    ap.add_argument("--recognizer", default="face_recognition_sface_2021dec.onnx")
    ap.add_argument("--low", type=float, default=0.30, help="detect at this score")
    ap.add_argument("--core", type=float, default=0.60, help="score at/above which YuNet "
                    "itself is confident (the 'agreed' set)")
    ap.add_argument("--default-thresh", type=float, default=0.5, help="the live pipeline "
                    "threshold; quality's value is judged on the set this threshold keeps")
    ap.add_argument("--tile", default="auto")
    ap.add_argument("--no-quality", action="store_true", help="embedding legs only")
    ap.add_argument("--out", default=None)
    opts = ap.parse_args()

    import cv2
    base = opts.models or os.environ.get("VISION_MODELS") or os.path.dirname(os.path.abspath(__file__))
    def p(name):
        return name if os.path.isabs(name) else os.path.join(base, name)

    net = None
    if not opts.no_quality:
        net = cv2.dnn.readNetFromONNX(p(opts.quality_model))
    sf = cv2.FaceRecognizerSF.create(p(opts.recognizer), "")
    det = cv2.FaceDetectorYN.create(p("face_detection_yunet_2023mar.onnx"), "", (64, 64),
                                    opts.low, 0.3, 5000)

    imgA = cv2.imread(opts.frame_a)
    if imgA is None:
        sys.exit(f"cannot read {opts.frame_a}")
    A, tA = scan(imgA, opts, det, sf, net)
    B, tB = (scan(cv2.imread(opts.frame_b), opts, det, sf, net) if opts.frame_b else ([], None))

    core = [r for r in A if r["score"] >= opts.core]
    marg = [r for r in A if r["score"] < opts.core]
    qc = [r["quality"] for r in core if r.get("quality") is not None]
    qm = [r["quality"] for r in marg if r.get("quality") is not None]

    report = {"low": opts.low, "core": opts.core, "frame_a": os.path.basename(opts.frame_a),
              "faces": len(A), "core_faces": len(core), "marginal_faces": len(marg),
              "timings_a": tA, "timings_b": tB}

    if qc and qm:
        report["quality_core"] = quartiles(qc)
        report["quality_marginal"] = quartiles(qm)
        report["auc_marginal_vs_core"] = round(auc(qm, qc), 3)
        report["auc_detscore_marginal_vs_core"] = round(
            auc([r["score"] for r in marg], [r["score"] for r in core]), 3)
        cuts = {}
        for q in (0.2, 0.3, 0.4, 0.5, 0.6):
            kept = sum(1 for v in qc if v >= q) / len(qc)
            dropped = sum(1 for v in qm if v < q) / len(qm)
            cuts[str(q)] = {"core_kept": round(kept, 3), "marginal_dropped": round(dropped, 3)}
        report["quality_cuts"] = cuts
        # does quality just restate the detector's own confidence?
        try:
            from scipy.stats import spearmanr
            allq = [r["quality"] for r in A if r.get("quality") is not None]
            alls = [r["score"] for r in A if r.get("quality") is not None]
            allw = [max(r["w"], r["h"]) for r in A if r.get("quality") is not None]
            report["spearman_quality_vs_detscore"] = round(spearmanr(allq, alls).statistic, 3)
            report["spearman_quality_vs_face_px"] = round(spearmanr(allq, allw).statistic, 3)
        except Exception as e:
            report["spearman_error"] = f"{type(e).__name__}: {str(e)[:80]}"

    # Non-circular FP test: split every box by whether it is still there a second later
    # (cross-frame persistence — the audit's reality proxy, and independent of det score),
    # then compare the two predictors on the SAME groups. Splitting core vs marginal by
    # det score would only prove det score predicts det score.
    if B:
        pers, trans = [], []
        for a in A:
            hit = any(iou(a, b) >= 0.3 for b in B)
            (pers if hit else trans).append(a)
        def qv(rows):
            return [r["quality"] for r in rows if r.get("quality") is not None]
        report["persistent"], report["transient"] = len(pers), len(trans)
        if qv(pers) and qv(trans):
            report["quality_persistent"] = quartiles(qv(pers))
            report["quality_transient"] = quartiles(qv(trans))
            report["auc_quality_pers_vs_trans"] = round(auc(qv(pers), qv(trans)), 3)
            report["auc_detscore_pers_vs_trans"] = round(
                auc([r["score"] for r in pers], [r["score"] for r in trans]), 3)
            cuts = {}
            for q in (0.1, 0.2, 0.3, 0.4):
                kept = sum(1 for v in qv(pers) if v >= q) / len(qv(pers))
                dropped = sum(1 for v in qv(trans) if v < q) / len(qv(trans))
                cuts[str(q)] = {"persistent_kept": round(kept, 3), "transient_dropped": round(dropped, 3)}
            report["quality_cuts_vs_persistence"] = cuts
        # within the set that actually survives the live default threshold, does quality
        # predict persistence? (that is the decision the pipeline makes)
        live = [r for r in A if r["score"] >= opts.default_thresh]
        lp = [r for r in live if any(iou(r, b) >= 0.3 for b in B)]
        lt = [r for r in live if not any(iou(r, b) >= 0.3 for b in B)]
        report[f"at_default_{opts.default_thresh}"] = {"faces": len(live), "persistent": len(lp),
                                                       "transient": len(lt)}
        if qv(lp) and qv(lt):
            report["auc_quality_pers_vs_trans_at_default"] = round(auc(qv(lp), qv(lt)), 3)
            report["worst_real_faces"] = sorted(
                [{"quality": r["quality"], "score": r["score"], "px": max(r["w"], r["h"])}
                 for r in lp if r.get("quality") is not None], key=lambda d: d["quality"])[:5]

    # question 2: does quality predict embedding stability on the SAME face across frames?
    if B:
        pairs = []
        for a in A:
            best = max(((iou(a, b), b) for b in B if iou(a, b) >= 0.3), default=None,
                       key=lambda t: t[0])
            if best and a.get("embedding") and best[1].get("embedding"):
                ca = sum(x * y for x, y in zip(a["embedding"], best[1]["embedding"]))
                pairs.append((a, best[1], ca))
        report["stable_pairs"] = len(pairs)
        if pairs:
            qs = [a.get("quality") for a, _b, _c in pairs if a.get("quality") is not None]
            cs = [c for a, _b, c in pairs if a.get("quality") is not None]
            report["same_face_cosine"] = quartiles(cs)
            try:
                from scipy.stats import spearmanr
                report["spearman_quality_vs_same_face_cosine"] = round(spearmanr(qs, cs).statistic, 3)
            except Exception as e:
                report["stability_corr_error"] = f"{type(e).__name__}: {str(e)[:80]}"

    print(json.dumps(report, indent=2))
    if opts.out:
        with open(opts.out, "w") as fh:
            json.dump({"report": report, "faces_a": [
                {k: v for k, v in r.items() if k != "embedding"} for r in A],
                "faces_b": [{k: v for k, v in r.items() if k != "embedding"} for r in B]}, fh)


if __name__ == "__main__":
    main()
