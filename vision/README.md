# Vision add-on — faces, mouths, and counts (opt-in)

An **optional** layer: a second Python 3.12 virtualenv, five model files (MediaPipe
landmarker/pose/blaze + OpenCV YuNet/SFace), and one probe script. It gives agent scripts a
way to ask *"how many faces are in this frame, and whose mouth is open"* without going through
Resolve at all — JSON out, no round trip through the edit engine. Detection and identity run on
**OpenCV YuNet + SFace** (MIT and Apache-2.0 weights, no extra dependency beyond OpenCV);
MediaPipe supplies the landmarks and mouth state, which OpenCV has no model for.

Nothing here is required for the Resolve workflow. Install it when you want face-level
signals alongside the audio/transcript analysis.

```bash
bash vision/install-vision.sh                  # venv ~560 MB + models ~52 MB
bash vision/install-vision.sh --dry-run        # print what it would do
bash vision/install-vision.sh --loose          # latest packages instead of exact pins
bash vision/install-vision.sh --venv /Volumes/YourMedia/vision-venv --models /Volumes/YourMedia/vision-models
```

Then:

```bash
~/resolve-vision-venv312/bin/python vision/face_probe.py --video master.mov --time 240
~/resolve-vision-venv312/bin/python vision/face_probe.py --image frame.png --tile 4x4
```

## Why a second venv, deliberately

The MCP server keeps its own venv, and its installer/doctor path recreates that venv — so
anything you `pip install` into it can be wiped by a repair. Keeping analysis dependencies
here means a server repair never takes the vision stack with it, and OpenCV/NumPy pins stay
yours instead of sharing one resolver with the server runtime.

If you specifically want the MCP server's built-in analyzer
(`media_analysis(action='strata_run', params={analyzers:['face']})`), that one needs
mediapipe + opencv *inside the server venv* — `--mcp-server-venv DIR` does it and prints the
trade-off first. Without those packages the server's face analyzer reports it can't run.

What lands where: venv at `~/resolve-vision-venv312` (override `--venv` or `$VISION_VENV`),
models at `~/resolve-vision-models` (`--models`, `$VISION_MODELS`). Models live outside the
venv on purpose: a venv is disposable, ~52 MB of model files are not. Nothing downloads itself
at run time — YuNet is 233 KB and SFace 38.7 MB, both fetched by the script — and every weight
in that directory has its licence stated below.

## Measured on real footage

One frame of 8128×4288 anamorphic HEVC from a multi-track choral recording (a wide shot of a
choir riser, faces 43–100 px wide), Apple M5 Ultra. Exact pins: mediapipe 1.2.2, opencv(-contrib)
5.0.0.93, numpy 2.5.4, Python 3.12.16 — `5.0.0.93` is the newest wheel on PyPI: OpenCV
**5.1.0** was tagged upstream 2026-11-06 with no Python wheels yet (checked 2026-11-07 against
`opencv-python`, `-contrib` and `-headless`), so there is nothing to move to, and one 5.1.0
change touches this stack (rule 4 below). When a 5.1 wheel does land, re-run
`face_probe.py` and `compare/` before trusting any number on this page. Re-runnable with
`vision/face_probe.py`; these are read-backs from that run, not estimates.

**Stage 1 — OpenCV YuNet detection (+ SFace embeddings) over native-resolution tiles:**

| Tile grid | Tile size | Faces | Detect only | Detect + SFace |
|---|---|---|---|---|
| 2×2 | 4064×2144 | 92 | 0.24 s | 0.95 s |
| **4×3 (the `auto` default)** | 2032×1429 | **90** | **0.29 s** | **0.96 s** |
| 4×4 | 2032×1072 | 93 | 0.31 s | 1.01 s |
| 8×4 | 1016×1072 | 92 | 0.40 s | 1.10 s |
| 8×8 | 1016×536 | 91 | 0.56 s | 1.26 s |

Yield is flat (90–93) across every grid; time is what changes, so `--tile auto` sizes tiles to
≤2048 px — the cheapest part of the curve. SFace's cost is the gap between the last two columns:
≈7.5 ms per aligned face. Model init is **0.0 s** (measured) — both ONNX files load straight into
OpenCV's own DNN reader — so a cold single-frame run (imports, detection, embeddings, landmarks)
is **2.19 s total**. Two honest caveats on the counts: they move with the score threshold (90 at
0.5, 97 at 0.4 on this frame), and with the frame's **encoding** — an H.264 re-encode of this
same frame read 94 faces.

**Stage 2 — MediaPipe landmarks + blendshapes on native crops around each detection:**
90 crops → **83 landmark sets** (478 landmarks, 52 ARKit blendshapes each) in **0.30 s**,
≈3.4 ms per face. (Detection counts and landmark hits are independent: a box can be right while
the mesh model declines to fit it, which is why 83 ≠ 90.)

## Four rules that cost real time to learn

1. **No detector here finds faces on a downscaled wide shot.** MediaPipe returns zero: measured
   0 faces at a 1600 px cap *and* at a 4032 px cap on a frame that genuinely held 90+, in under
   1 ms per call. Its internal face detector runs at a fixed input size, so what matters is a
   face's **share of the frame**, not the frame's pixel count — a 95 px face in an 8128 px frame
   is ~1.2% of the width and simply isn't there after the resize. An untiled whole-frame YuNet
   call is worse than nothing: it returned **one box covering the entire image at score 0**.
2. **So work at native resolution, in two stages.** YuNet scans native tiles (`setInputSize` per
   tile, and YuNet's documented working range is 10×10–300×300 px faces — riser rows sit right
   in it); FaceLandmarker then lands landmarks on a native crop around each detection (default
   1.6× margin, `num_faces=1`). Same frame: 0 faces whole-frame, 6/6 on crops.
3. **MediaPipe 1.x removed `mp.solutions.*`.** Use the Tasks API —
   `FaceLandmarker.create_from_options`, model via `base_options=BaseOptions(model_asset_path=…)`,
   knobs named `min_face_detection_confidence` / `min_face_presence_confidence` (there is *no*
   `min_presence_confidence` on `FaceLandmarkerOptions`; that field belongs to `FaceDetector`),
   and wrap OpenCV arrays as `mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)` — a bare
   ndarray raises. Two more from the OpenCV side: `FaceDetectorYN.create(...)` and
   `FaceRecognizerSF.match(a, b, dis_type)` take their options **positionally** in OpenCV 5
   (keyword arguments raise), and a YuNet row is `[x, y, w, h, lx1, ly1 … lx5, ly5, score]` —
   those five landmarks feed `alignCrop`, which is the only correct input to SFace.
4. **`FaceRecognizerSF.match()` rewrites the vectors you hand it.** Measured on 5.0.0.93: both
   arguments are L2-normalised **in place** (norm 9.92 → 1.00), so a pairwise-distance loop
   silently converts the embeddings you were holding. The reported distance is unaffected (cosine
   stays cosine), which is what makes this easy to miss — but anything that later reasons about
   raw activations, normalises a second time, or stores those arrays for a second pass is now
   working on different data than it thinks. Fixed upstream in OpenCV **5.1.0** ("do not modify
   the input features in `FaceRecognizerSF::match`", merged 2026-08-28). Normalise explicitly and
   keep the originals, which is what `compare/recog_quality.py` does.

## What it actually buys you

- **Cross-check the audio against the picture.** `jawOpen` per face, per frame, tells you who
  was physically producing sound during a solo — the thing a bad boom choice or a spill from
  the neighbouring stand makes expensive to find by eye. Pipe the JSON into a timeline marker
  pass and an agent can propose where to look.
- **Shot-level counts without a human viewer.** Faces per frame is a cheap coverage signal:
  wide vs tight, who is on screen, whether a take has anyone's face at all.
- **Distinct-people counts**, if you opt into embeddings (`--save-embeddings`, 128-d SFace
  vectors, L2-normalised so a dot product is a cosine) and cluster them yourself. Treat the
  count as an estimate: at the model's own 0.363 threshold this footage measured 2.0% of
  different-person pairs scoring as the same person.
- **The mouth signal you want is the blendshape, not a lip-gap ratio.** On this footage a
  singer holding a rounded vowel measured `jawOpen 0.43` while a vertical inner-lip gap read
  0.02 — the mouth *is* open, puckered (`mouthPucker 0.998`), and the geometric heuristic
  calls it closed. That disagreement happens exactly where it matters, so the script reports
  both and flags on `jawOpen`.
- **A pre-flight frame check for agent edits:** a script can sample N frames per clip and
  reason about content before proposing cuts or before choosing an angle.

## Limits worth stating

- **Landmark coverage is pose-dependent.** 83/90 on a frontal choir riser; **0/3** on a wide
  auditorium frame where the audience faced away and the two people on stage were in profile —
  detection still fired on those three, landmarks did not (that frame was probed on the
  pre-swap stack; re-run it if the number matters to you). A low number is usually the shot, not
  the tool — a wide shot of an empty stage really does hold 3 faces.
- **The score threshold is a real tuning knob, and the sample default is wrong for this
  footage.** OpenCV's Zoo `demo.py` ships `--conf_threshold 0.9`; on this frame that returns
  **56 faces instead of 89**. Measured curve (faces 43–100 px): 0.90 → 56 · 0.75 → 86 ·
  **0.60 → 89 · 0.50 → 90** · 0.45 → 93 · 0.30 → 98. Past that, you're buying noise: of the 9
  boxes 0.30 adds over 0.60, only 4 were still present a second later, and three were legs, a
  music folder, and a 289×239 box around three torsos. Default stays **0.5**; the band that held
  up is 0.50–0.60. Audit your own with `compare/threshold_audit.py` — it cross-frame-checks
  persistence and prints a contact sheet of the marginal boxes, because a bigger count is not
  the same thing as more faces.
- **Feeding SFace a raw bbox crop is a silent catastrophe.** Same model, same frames, aligned
  vs unaligned input: same-person cosine median **0.901 → 0.249**, and the fraction of the same
  person's faces judged *different people* goes **1.1 % → 63.2 %** (AUC 0.999 → 0.769) — a
  distinct-people count inflated roughly 2.5×. `alignCrop` uses YuNet's five landmarks; nothing
  in the API stops you from skipping it.
- **Mouth thresholds are calibrated on one session** (n=1 choral recording, faces ~43–100 px):
  `jawOpen` 0.24–0.73 while singing, ≤0.03 at rest, default flag at 0.20. Verify on your own
  footage before trusting it.
- **MediaPipe Pose detects at most 3 people per call.** Never read group counts from pose.
- **This is not Resolve's own AI.** Resolve's face refinement / IntelliSearch run inside the
  app on its own accelerators and integrate with its colour and search UIs. This layer exists
  for *scriptable, offline, JSON-shaped* answers — including on machines or clips where you
  don't want to involve Resolve at all.
- Frames here are decoded by OpenCV, so anamorphic sources arrive *squeezed* (this footage is
  8.1K behind a 1.33× anamorphic adaptor). Detection tolerates it; a face-shape heuristic on
  desqueezed vs squeezed pixels will not agree with itself, so state which you measured.

## Privacy — read this before you run it on client footage

Face geometry and 512-d embeddings are **identity data**. Consequences I hold myself to, and
suggest you keep:

- Default output carries boxes, scores and scalar mouth state — **no vectors**. Vectors appear
  only with `--save-embeddings`, and the script prints a warning naming the file it wrote.
- Keep those files off anything shared or exported: not in a repo, not in a page, not beside
  deliverables. This repo's pre-commit scan blocks named clients/projects; identity data needs
  a stricter rule — *don't export it at all*. If the footage includes minors, treat any
  derived face data as not-for-export without asking.
- Decide retention with the client, and delete the scratch when the job closes. The JSON and
  `.npz` artifacts from my own runs sit in a per-project scratch directory on a work volume,
  not in this repo.
- Model downloads come from Google's MediaPipe storage and the OpenCV Zoo (GitHub); nothing in
  this add-on uploads anything, and nothing downloads at run time.

## Licences (verify before commercial use)

- **MediaPipe** code is Apache-2.0 (its repo LICENSE). The hosted `.task`/`.tflite` model
  pages I downloaded from carry **no licence line**, so check those terms yourself for
  commercial work.
- **What this add-on installs now**: OpenCV **YuNet** detector weights — **MIT** (`LICENSE` in
  the OpenCV Zoo model directory, copyright Shiqi Yu; the model card says "All files in this
  directory are licensed under MIT License") — and **SFace** recogniser weights — **Apache-2.0**
  (same, its own directory). Both classes ship inside `opencv-contrib-python` ≥ 4.8, so the two
  files add ~39 MB and no dependency. Measured on the 8.1K frame below: **90 faces**, 0.29 s
  detection, 0.0 s model init.
- **The rule this stack follows:** read the licence of the **weights**, not of the library that
  loads them. A permissively-licensed loader can pull weights carrying a research-only clause, and
  that clause follows the embeddings you derive from them. Every model file under
  `~/resolve-vision-models` here was checked that way before it was installed, and the two that
  are not fully clear are flagged above.

## Judging another detector before trusting it

Two checks that have already paid for themselves, both run through `compare/`:

- **Model vintages can be a no-op.** OpenCV Zoo's newer `face_detection_yunet_2026may.onnx` gave
  identical counts to `2023mar` (98 / 90 / 89 at score 0.30 / 0.50 / 0.60) and box-for-box
  identical geometry — mean IoU **1.000**, zero unmatched. It is not installed.
- **Don't mix detectors across stages.** MediaPipe's own blaze detector agrees with YuNet on only
  **15 of 90** boxes on this frame (mean IoU 0.53): blaze is a near-range model, and the choir's
  faces are 43–100 px in a 8128 px frame. That is exactly why detection and landmarks are separate
  stages here — blaze-style detectors are fine for the landmark pass on a crop, useless for the
  count.

A candidate earns its place by matching boxes with the incumbent detector (IoU ≥ 0.3, mean IoU
reported), not by producing a bigger count. `compare/merge_compare.py` does the matching;
`compare/recog_quality.py` measures recognition separability without labels, and its
`--align bbox` control is how the alignment result above was derived.

### The two Zoo items I tried and did not keep (measured, not assumed)

Both were downloaded and run against this footage; neither is in the installer. The reason is
in each row, and `compare/` reproduces both.

**Quantised SFace** — `compare_detectors.py --recognizer <build>` on two frames 1 s apart,
90 faces each, 88 position-matched same-face pairs and 8007 different-face pairs:

| SFace build | weight | embedding wall | same-face cosine median | splits same person | merges different people | AUC |
|---|---|---|---|---|---|---|
| `2021dec` (**installed**, fp32) | 38.7 MB | 0.67 s (7.5 ms/face) | **0.901** | 1.1 % | 2.0 % | 0.999 |
| `2021dec_int8` | 9.9 MB | **1.44 s (16 ms/face)** | 0.879 | 1.1 % | 2.0 % | 0.999 |
| `2021dec_int8bq` | 10.7 MB | — *does not load*: `-215 Assertion failed (ninputs == 1 …)` in OpenCV 5's new graph engine | | | | |

The quantised build is **2.1× slower per face** on this build (quantised ops aren't accelerated
here), loses 0.022 of same-face cosine, and buys only a 29 MB smaller download — so the
"quantise to go faster" instinct is wrong for this stack. Separately, the two builds' vectors
are *near* but not interchangeable: same face scores cosine median **0.954** (min 0.784) across
builds, and an fp32 library queried with int8 vectors merges **1.6 %** of different-person pairs
at the 0.363 threshold. Don't mix them inside one identity library.

**eDifFIQA face-image-quality** (`ediffiqa_tiny_jun2024.onnx`, 7.3 MB, **CC-BY-4.0** — the only
weight in Zoo's face family here that isn't MIT/Apache) — `compare/quality_filter.py`, YuNet at
score 0.30 on the same frame: 98 candidate boxes, **91 still present 1 s later, 7 gone**.

| question | result |
|---|---|
| Can a quality score spot the junk boxes better than YuNet's own score? | **No.** AUC(persistent vs transient): quality **0.838** vs det score **0.832** — the same information, and it tracks det score (Spearman 0.686) rather than adding to it |
| Is there anything left to filter at the live default 0.5? | 90 faces → 88 persistent, 2 transient; quality AUC there is **0.54**, a coin flip |
| Do its published bands transfer to a wide shot? | **No.** The model card's "high quality > 0.5" is the extreme top here (max 0.57, median 0.39); genuine persistent faces score as low as **0.006** (det score 0.75) |
| What would it cost to run on every face? | **4.6 ms/face** (0.45 s for 98) — ~60 % of the SFace embedding leg, for a second opinion that agrees with the first |
| Could it at least gate the identity pass? | Weak: Spearman(quality, same-face cosine) **0.394**. Skipping embeddings on "low quality" crops risks real people to save 7.5 ms |

The rule this taught me, worth carrying: **a candidate has to beat the signal you already have,
scored on the same groups.** Splitting detections into "confident" and "marginal" by detection
score and then showing a quality model separates them proves nothing — that's detection score
predicting detection score. Cross-frame persistence is the label-free reality proxy that makes
the comparison fair, and it says the quality model is redundant here.

## Files

| File | What it is |
|---|---|
| `install-vision.sh` | Builds the pinned 3.12 venv, fetches the five model files (MediaPipe landmarker/pose/blaze ×2 + YuNet + SFace), loads each one to prove it isn't truncated, optionally patches the MCP server venv. `--dry-run` is honest: it writes nothing. |
| `compare/` | The harness for judging detectors and models: one backend per process, IoU matching across runs, label-free recognition separability (`--recognizer` swaps the SFace build for quantisation A/B), `threshold_audit.py` for deciding a score threshold on *your* footage, and `quality_filter.py` for testing a quality-assessment model as a false-positive filter — persistence-based groups, with detection score as the competing predictor. Keep it to re-derive any number here, or to check a future model before it goes near the pipeline. |
| `face_probe.py` | Frame → JSON: native-tile detection, merged cross-tile duplicates, per-face crops → landmarks + blendshapes, optional embeddings. Its docstring carries the API gotchas above. **stdout is pure JSON**; the noise you see is MediaPipe's own glog chatter on stderr — silence it with `2>/dev/null` when parsing. |
