> **Disclaimer**
>
> This content describes a method for running a local large language model (LLM) on a Mac Studio in conjunction with DaVinci Resolve Studio version 21.1 or later. It is provided for informational purposes only and does not constitute a guarantee of suitability, performance, or fitness for any particular purpose. Nothing herein should be construed as a recommendation to purchase any specific hardware, including an M5 Ultra Mac Studio or any other model.
>
> The author assumes no responsibility or liability for any decisions made based on this information, including any purchase of hardware, or for any resulting costs, performance shortfalls, or other consequences. Users are solely responsible for independently evaluating their own requirements and determining the adequacy of any hardware or software configuration for their intended use.
>
> This stack is independent of Blackmagic Design, Inco AI, and Anthropic; those names appear only because the tools are used.

# DaVinci Resolve + Local AI Workstation

A complete, scripted post-production workstation: **OpenCode driven by a
fully local LLM**, operating **DaVinci Resolve Studio** through three MCP
servers, with **Blender rendered headless** for titles and generated content,
and a **live observability dashboard** — on one Apple Silicon Mac, no cloud,
no API keys for the editor path.

People kept asking how the setup works; this repo is the answer, as scripts.

```
┌─────────────────────────────  one Mac Studio (Apple Silicon)  ─────────────────────────────┐
│                                                                                           │
│  Splash (brew) ── serves Qwen Flash-Next IQ3_S on :8000  ←→  splash-dashboard on :8280    │
│      │  OpenAI-compat + Anthropic-compat; persistent SSD prefix cache                     │
│      ▼                                                                                    │
│  OpenCode     (opencode — the agent IS the model you run locally)                         │
│      │  MCP (stdio)                                                                       │
│      ├── davinci-resolve            community Python MCP  — live editing/render/guardrails │
│      ├── davinci-resolve-advanced   community Node MCP    — offline DB/DRX/DRT/QC          │
│      ├── DaVinci Resolve            official Blackmagic MCP (ships in Studio 21.1+)       │
│      ├── brave-search (optional)    official Brave MCP    — web research (paid key)       │
│      ▼                                                                                    │
│  DaVinci Resolve Studio 21.2  ←── EXR title sequences rendered by headless Blender        │
│      ▲                                       (Cycles on Metal, film_transparent)          │
│      └── ffmpeg/ffprobe — QC read-backs, sequence encoding, frame extraction              │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

*Data never leaves the machine except through the optional Brave Search leg.*

## Contents

- [What each piece brings](#what-each-piece-brings)
- [Quick start](#quick-start)
- [What agentic control actually does here](#what-agentic-control-actually-does-here)
- [What the vision layer gets you](#what-the-vision-layer-gets-you-opt-in)
- [Transcription: which tool, and where the models live](#transcription-which-tool-and-where-the-models-live)
- [Benchmarks (measured, reproducible, honest)](#benchmarks-measured-reproducible-honest)
- [Operating practices that keep it trustworthy](#operating-practices-that-keep-it-trustworthy)
- [Troubleshooting quick hits](#troubleshooting-quick-hits)
- [Verified stack](#verified-stack)
- [License](#license)

## What each piece brings

| Tool | Benefit |
|---|---|
| **Splash 1.7.0** ([incoai/tap](https://github.com/incoai/splash), brew) | Local LLM engine serving `Qwen3.8-Flash-Next IQ3_S` (262k context, GGUF/IQ3 quant) behind OpenAI *and* Anthropic-compatible APIs. Persistent disk prefix-cache reuses a fresh session's shared prefix at ~99.7% (measured 2026-11-17: 9,664 of 9,690 tokens served to a *different* session, 125 ms; production agent prefixes run ~20–45k by that same path). On 1.7.0: **TTFT 110–118 ms warm** / 291 ms cold, ladder single-stream **219.8 tok/s** (probe decode ~170), **aggregate plateau 479–494 tok/s** across widths 8→32 with the peak at width 4 (526.5). Also hosts a built-in chat UI on :8000. |
| **OpenCode** ([opencode.ai](https://opencode.ai)) | The agentic operator. Reads the timeline, plans edits, executes them through MCP with dry-run/confirm-token discipline, verifies via read-backs, renders, grades its own output with ffprobe. Nothing leaves the machine. Replaced Claude Code on 2026-11-16 on measured evidence — see `HARNESS-MIGRATION.md`. |
| **Community `davinci-resolve` MCP** ([samuelgursky/davinci-resolve-mcp](https://github.com/samuelgursky/davinci-resolve-mcp)) | The hands: ~36 action-dispatch tools over the whole scripting API — media pool, timelines, ripple edits with dry-run plans, markers, Fusion comps, render queue + **verified outputs** (ffprobe cross-check of every render), and a live `api_truth` knowledge base of verified Resolve API quirks. Destructive ops auto-archive timelines first. |
| **`davinci-resolve-advanced` MCP** (same project) | The forensic layer: closed-`Project.db` reads/writes (captions, speed ramps), `.drx` grade XML, DRT timelines, FCPXML/EDL/AAF conform, deliverable-QC specs — all without Resolve running. |
| **Official ResolveMCP** (bundled in Resolve Studio 21.1+) | Blackmagic's own 18-tool surface: canonical and versioned with the app; useful cross-check and fallback. |
| **Brave Search MCP** (opt-in: official `@brave/brave-search-mcp-server`, MIT) | The research leg — the only one that costs money: live fact-checks no model can know, like whether a new Resolve build changed an API behaviour or whether an upstream release has wheels on PyPI yet. Priced **$5 per 1,000 queries**, with **$5 of free credit applied automatically every month** (~1,000 free queries; card required at signup even for free use). The only leg where queries leave the machine — search strings get the same scrubbing discipline as commit messages. Setup, pricing details and a plan-bound-key gotcha in [`mcp/mcp-config.md`](mcp/mcp-config.md). |
| **splash-dashboard** ([rickhuizinga/splash-dashboard](https://github.com/rickhuizinga/splash-dashboard)) | Live engine observability on :8280: KV residency, prefix-cache hit rate, admission pacing, decode batch widths — the instrument panel that turns "the model feels slow" into numbers. |
| **Prometheus + Grafana** (opt-in; not installed by `install.sh`) | History leg: the engine serves native Prometheus text at `/metrics` (~130 `splash_*` series). If you have already installed and provisioned Prometheus + Grafana, the launcher starts them (`--no-metrics` skips). A fresh machine does **not** get them automatically — one-time setup is required (`start.sh` header comments spell out the Grafana 13 provisioning gotcha: `[paths] provisioning = …` **plus** `permitted_provisioning_paths`, or provisioning silently loads nothing). Until then the live dashboard on :8280 is sufficient. |
| **Blender (LTS, at `/Applications`)** | Content forge: 3D title stings, extruded logos, generated media — scripted headless (`--background --python`), rendered transparent-EXR, imported into Resolve as sequence clips with straight alpha. See [`blender/`](blender/). |
| **ffmpeg / ffprobe** (brew) | The verification layer: every render gets probed (frame count, codecs, duration) before it's trusted; sequence encoding; frame extraction for visual checks. |
| **whisper.cpp / whisper CLI** (brew + MCP-integrated) | Local transcription; the MCP server also feeds transcripts into timeline subtitle tracks and cut-candidate proposals. |
| **Vision add-on** (opt-in: `install.sh --vision`, see [`vision/`](vision/)) | Face-level signals off Resolve: OpenCV YuNet + SFace for detection/identity and MediaPipe for landmarks, in their own Python 3.12 venv. 90 faces detected on one 8.1K frame in 0.29 s (0.96 s with embeddings, 0.0 s model init), 83 of them landed 478 landmarks + 52 ARKit blendshapes in another 0.3 s — so "whose mouth was open during this solo" becomes a JSON query. Opt-in because it's a second venv (~560 MB + ~52 MB models); every weight it installs has a stated licence. |
| **macmon** (brew) | Zero-overhead Apple GPU/memory/ANE telemetry in a second terminal — watch unified-memory pressure while Resolve renders and the engine serves, which is how the 56 GB memory budget below was chosen. |

### Which Resolve MCP to use

- **Day-to-day agent work** (timeline edits, markers, Fusion, render queue, verified outputs): community `davinci-resolve`. It has the dry-run / confirm-token / auto-archive guardrails.
- **Closed-project forensics** (Project.db, .drx grades, DRT, conform without Resolve open): `davinci-resolve-advanced`.
- **Canonical Blackmagic surface / cross-check / fallback**: official `DaVinci Resolve` (ships inside Studio 21.1+).

Most sessions use the community server as primary and keep the official one registered as a safety net. Details and registration steps are in [`mcp/mcp-config.md`](mcp/mcp-config.md).

> **Do not** run a blanket `pip install -U` inside the community server's venv — it carries its own pins (`mcp` SDK 1.30.0 plus a torch/transformers stack). The only update path is `npx -y davinci-resolve-mcp@latest sync`; see [Verified stack](#verified-stack).

## Quick start

**Requirements**

- Apple Silicon Mac, ideally ≥48 GB unified memory (tuned here on 96 GB;
  the engine prints its own recommended working set on smaller ones).
- **DaVinci Resolve Studio** required for external scripting (the path this
  launcher and the stdio MCP servers use). The free edition reaches the
  community server only via the in-app bridge (Workspace ▸ Scripts) on 21.0.x;
  Resolve 21.1 moved Python scripting to Studio, so from 21.1 on even that
  bridge path is gone. The official Blackmagic MCP always needs Studio.
- In Resolve Studio set **Preferences → System → General → External scripting
  using** to **Local**, then restart Resolve if it is already open. Without
  this the community MCP servers cannot connect.
- macOS with Homebrew; Python 3.11+; Node 20+. `install.sh` stops and tells
  you if Homebrew is missing; it installs Node via Homebrew when absent, but
  expects a Python 3.11+ already available (the MCP installer requires it).
- Optional Blender LTS: `brew install --cask blender` (or download from
  blender.org). `install.sh` checks for it and prints this hint, but never
  installs it itself.

```bash
git clone https://github.com/willturner-maker/resolve-ai-workflow.git
cd resolve-ai-workflow
bash install.sh            # everything below, wired into OpenCode
bash install.sh --vision   # same, plus the opt-in face/mouth layer (vision/README.md)
bash install.sh --lsp      # + LSP tool & post-edit diagnostics for OpenCode V2 (project-scoped)

# After install, open a NEW terminal — the launchers arrive on PATH as:
start.sh                   # Splash → dashboard → metrics (opt) → Resolve → OpenCode
stop.sh                    # clean shutdown (leaves Resolve alone)

# From the clone, without relying on PATH:
bash start.sh
bash stop.sh

# Thinking depth for the launch (the default is `medium`; the engine applies it
# to any request that asks for none — the Chat UI and OpenCode both send none):
bash start.sh --xhigh      # deepest deliberation (~3x thinking tokens, ~40% slower)
bash start.sh --low        # or --high; also accepts --effort=<value> / REASONING_EFFORT=<value>
```

> **First start:** the model download is tens of GB and can take several
> minutes; subsequent starts take seconds. Watch the terminal until the
> dashboard URL appears and OpenCode opens.

> **Disk:** the model itself is a one-time download. The persistent prefix
> cache can grow up to `MAX_CACHE_DISK` (default 256 G). An external SSD is
> recommended for the cache — see the `EXTERNAL_CACHE` variable in `start.sh`.

### First-run checklist

1. `bash install.sh` finishes and prints the registered MCP servers
   (the three Resolve names — plus `brave-search` if you opted in).
2. Open a **new** terminal so PATH picks up the launchers.
3. `start.sh` — first start downloads the model; later starts
   begin in seconds.
4. The dashboard comes up on :8280, then OpenCode opens. Resolve is
   **not** launched: the MCP starts it headless (`-nogui`) on the first
   Resolve tool call. To open the GUI at boot instead, prefix the start
   with `LAUNCH_RESOLVE_GUI=1`.
5. Verify the servers: `opencode mcp list` — expect the three Resolve names.
6. Optional: `macmon` in a second terminal to watch unified-memory pressure.
7. Confirm the MCP path with a read-only probe — in OpenCode ask:
   `List the timelines in the current Resolve project (read-only)`. (The
   probe needs a project open; the agent can create or load one headless.)
   A reply naming your timelines means the whole chain
   (engine → MCP → Resolve) works.

**If the engine never becomes ready:** `tail ~/Library/Logs/splash/splash.err.log`
(the dashboard leg logs to `~/splash-dashboard.log`).
**If MCP servers are missing:** re-run `npx -y davinci-resolve-mcp@latest setup
--clients opencode`, then `opencode mcp list` to confirm and restart the session.
**If memory pressure turns red:** lower `MAX_MEMORY` and restart (sizing table below).

> The dashboard at `http://127.0.0.1:8280` shows engine status, KV residency,
> and cache hit rate — the fastest way to confirm Splash is healthy before
> talking to the agent.

First start downloads the model (tens of GB) into Splash's cache and can take
several minutes. Subsequent starts are seconds once the weights are cached.

The launcher's memory numbers are tunable without editing the script. Defaults
are sized for a 96 GB machine running Resolve concurrently; smaller machines
should lower them (see table below).

```bash
# example for a 64 GB machine
MAX_MEMORY=32G MAX_CACHE_DISK=64G start.sh

# or with the prefix cache on a fast external SSD
MAX_MEMORY=56G MAX_CACHE_DISK=128G EXTERNAL_CACHE="/Volumes/YourSSD/splash-cache" start.sh
```

**Suggested starting points by machine size** (the engine also prints its own
recommended working set at startup):

| Unified memory | Suggested `MAX_MEMORY` | Suggested `MAX_CACHE_DISK` | Notes |
|---|---|---|---|
| 96 GB | 56G (default) | 256G (default) | Measured on M5 Ultra + Resolve — 256G is the value since 64G saturated and started evicting warm prefixes |
| 64 GB | 32–40G | 64G | Leave headroom for Resolve |
| 48 GB | 24–28G | 32–64G | Watch system pressure; engine recommendation is authoritative |

Rough disk use on first run:

- Model weights (Splash cache): tens of GB (one-time download)
- Persistent prefix cache: up to the `MAX_CACHE_DISK` value (default 256G; lives under `~/Library/Caches/Splash/` unless `EXTERNAL_CACHE` points elsewhere)
- Vision add-on (opt-in): ~560 MB venv + ~52 MB models
- Blender: separate application install

**Optional hardening:** `bash tools/precommit-scan.sh --install` enables the
local-string guard described under
[Operating practices](#operating-practices-that-keep-it-trustworthy) — worth
wiring up before you commit anything of your own into a clone.

- `start.sh` / `stop.sh` — the exact scripts this workstation runs (with the
  memory-tuning log in the header comments: why 56 GB working set / 128 GB disk
  cache on a 96 GB machine next to a running Resolve).
- `mcp/mcp-config.md` — how the three Resolve MCP servers (plus the optional
  `brave-search` research companion) are registered, verified and updated, and why
  all of them are kept side by side.
- `blender/` — the title pipeline: `exr_title_demo.py` + a README of every
  Blender 5.x gotcha and the Resolve import specifics (multi-path EXR import,
  Alpha mode → Straight, end-exclusive append frames, proof-render verification).
- `vision/` — opt-in face/mouth analysis: `install-vision.sh` (pinned 3.12 venv +
  MediaPipe model downloads) and `face_probe.py` (frame → JSON), plus the measured
  numbers, the three API rules that cost the most time, and the privacy rules.

## What agentic control actually does here

Not a demo reel — production tasks this stack has completed end to end:

- **Editorial surgery with receipts**: ripple-inserts and lifts planned by dry-run,
  executed under confirm tokens, verified by geometry read-back (every item's
  start/end re-measured), timeline auto-archived before the mutation.
- **Renders that verify themselves**: queue job → Complete → `verify_output`
  probed the file → caught a "Complete" job that produced a near-empty stub.
  The agent trusts the probe, never the status line.
- **Fusion comp scripting**: keyframe a live comp via script, then prove the
  change by rendering frames — stills grabs lie about comp output; renders are truth.
- **Bulk triage**: color-flag dozens of clips in one call, marker-driven review
  reports, transcript-driven cut proposals (filler/pause detection) that a human
  approves before anything is cut.
- **Blender ↔ Resolve round trips**: script a 3D logo sting, render 90 UHD
  transparent frames overnight, import, set straight alpha, ripple-insert at the
  master head, proof-render 420 frames over the seam, sample frames to confirm.
- **Cross-tool forensics**: closed-project DB reads (captions, speed ramps) and
  conform imports validated without disturbing the live session.

## What the vision layer gets you (opt-in)

The Resolve MCP can already transcribe and analyse media, but face-level questions were
either Resolve's own black-box AI or nothing at all. This layer makes them scriptable,
offline and inspectable — one command, JSON out, no Resolve round trip.

**What it does now, measured on a real 8128×4288 anamorphic HEVC frame from a choral
recording** (M5 Ultra, pinned versions, re-runnable with `vision/face_probe.py`):

| Stage | Result | Wall |
|---|---|---|
| Detection, native-resolution tiles (OpenCV YuNet) | **90 faces** on one frame | **0.29 s** (0.96 s including SFace embeddings; **0.0 s** model init) |
| Landmarks + blendshapes on native crops (MediaPipe) | **83 of 90** landed 478 landmarks + 52 ARKit blendshapes | **0.30 s** (~3.4 ms/face) |
| End to end | 90 faces, mouth state on most of them | **2.19 s** cold, whole process (imports included) |

Concrete benefits:

- **Who was actually singing.** `jawOpen` per face per frame cross-checks a solo against the
  audio — the question a bad boom choice or a spill from the next stand makes expensive to
  answer by eye. Feed the JSON to the marker/subtitle tools and an agent can propose where to
  look instead of scrubbing.
- **Coverage signals without a human viewer:** faces per frame (wide vs tight, whether a take
  has anyone's face at all), and with opt-in embeddings, distinct-people counts.
- **A pre-flight content pass:** sample N frames per clip before an agent proposes cuts or
  picks an angle.
- **A blendshape is the right mouth signal, not a lip gap.** Measured disagreement on exactly
  the case that matters: a singer holding a rounded vowel read `jawOpen 0.43` while a vertical
  inner-lip gap read `0.02` — open, puckered (`mouthPucker 0.998`), and the geometric shortcut
  calls it shut.

Three rules it encodes, because each one cost debugging time: **neither library finds faces on
a downscaled wide shot** (MediaPipe returned 0 faces at a 1600 px *and* a 4032 px cap on a
frame holding 90+ — its detector is fixed-input, so a face's *share* of the frame is what
matters); **so detect on native tiles, then landmark on native crops** (same frame: 0 faces
whole-frame, 6/6 on crops); and **MediaPipe 1.x dropped `mp.solutions.*`** — Tasks API names
only, `min_face_presence_confidence` not `min_presence_confidence`, and OpenCV arrays must be
wrapped in `mp.Image`. Full set in [`vision/`](vision/).

Honest limits: landmark coverage is pose-dependent (83/92 on a frontal riser, **0/3** on a
wide shot where people were in profile or facing away — a low count is usually the shot); the
mouth threshold comes from **one** session (n=1, faces ~47–95 px: 0.24–0.73 singing, ≤0.03 at
rest); MediaPipe Pose caps at 3 people per call, so never count a crowd with pose.

**Privacy:** face geometry and 128-d SFace embeddings are identity data. The default output
carries boxes, scores and scalar mouth state only; vectors appear solely with
`--save-embeddings`, which prints a warning naming the file. They stay out of repos, pages and
deliverables — the publish-scan below blocks *names*; identity data needs the stricter rule of
not being exported at all, especially for footage with minors. Model weights are downloaded from
Google's MediaPipe storage and the OpenCV Zoo; nothing here uploads anything.

## Transcription: which tool, and where the models live

Three local options, chosen by the question rather than by model size:

| Question | Use | Cost |
|---|---|---|
| "What was said, roughly when" — subtitles, search, cut candidates | **whisper.cpp** (installed by `install.sh`; the MCP server's subtitle and cut-proposal tools ride on those transcripts) | `base` weights ≈ 150 MB, no Python env |
| **Word-level** grounding — which word lands at which frame, per-singer timing behind a marker or a zoom cue | **WhisperX** (CTranslate2 `large-v3` + wav2vec2 CTC alignment) | 4.2 GB weights + ≈1.5 GB venv (torch rides along) |

Word-level alignment is the only reason to have WhisperX; faster-whisper's segment timestamps
cover everything else. Measured on real multitrack choral audio, M5 Ultra, CPU, `int8`:
**167 s of audio in 48.6 s**, a 46-minute act in **638 s** (≈4× faster than realtime) — and
that is the ASR pass alone; alignment is a second sweep over the same audio.

**One shared model cache, not one per project.** WhisperX reaches HuggingFace through two
channels that expect *different paths*, and the mismatch is silent — it simply re-downloads
≈4.4 GB:

- `whisperx.load_model(..., download_root=X)` uses X **directly** as its hub dir
  → `X/models--Systran--faster-whisper-large-v3/…`
- the alignment pipeline goes through `transformers`, which honours `HF_HOME`
  → `$HF_HOME/hub/models--jonatasgrosman--…/…`

So both must point at the same directory, kept on a media volume rather than the boot disk:

```bash
export WHISPERX_HF="/Volumes/YourVolume/local.AI/WhisperX/hf"  # ~4.2 GB, reused by every project
export HF_HOME="$WHISPERX_HF"          # before importing whisperx, not after
```

Put those two exports in the venv's `bin/activate` as well as the shell profile, so a fresh
environment cannot forget them.

Two tidy-ups cut 2.1 GB from the 6.4 GB download: the alignment repo ships five weight
formats plus a fairseq n-gram decoding LM, and the HF CTC pipeline loads exactly one of each
(keep `model.safetensors` + config/vocab/preprocessor; drop `pytorch_model.bin`, `lm.binary`,
`unigrams.txt`). When pruning, remove a snapshot entry **together with the blob it points at**,
then look for blobs no snapshot references — a half-pruned repo leaves ~800 MB behind that
nothing reports as stale.

## Benchmarks (measured, reproducible, honest)

The stack ships with its own benchmark practice — full docs, scripts and raw
JSONL at **https://github.com/willturner-maker/benchmarks**. Headlines:

- **Agentic correctness**: 6 task types × 3 fresh agents each, graded only from
  independent read-backs of Resolve state: **18/18 outcomes verified, 18/18 honest
  reports** (across MCP 4.18.5 and 4.19.0, Resolve 21.1.2 and 21.2).
- **Operation latency** (server-side medians): timeline probe ~11 ms,
  render-job prepare ~130 ms, output verification ~40 ms, timeline-set ~100 ms.
- **Render probe** (121-frame UHD H.264 from an 8K source): cold ~3.1 s,
  warm ~1.2–1.3 s (~93–100 fps), stable run to run single-tenant.
- **Engine** (Splash 1.7.0, re-measured 2026-11-17 across three passes, plus a zero-tenancy
  clean-window pass the same day): TTFT
  **110–118 ms warm** / 291 ms cold; ladder w1 **219.8 tok/s** (clean window: **225.2**, best
  recorded), plateau **479–494 tok/s**
  across widths 8→32 with the aggregate peak back at **width 4** (526.5; clean window **543.8**,
  best recorded); KV admission
  still paces gracefully — **zero suspensions at 611k prompt tokens** (3.93× a
  155,648-token resident budget, itself +18.8% on 1.6.1) with the quietest demote path
  on record (+11 blocks total, zero spill).

Version-to-version reruns are scripted (`ladder_kv.py` runs both concurrency
methods in one pass), which is how upgrades get trusted — including the time an
upstream bug we filed (#343) came back fixed and got verified by direct probe
the same day it shipped.

## Operating practices that keep it trustworthy

1. **Dry-run first** — the MCP server defaults destructive ops to plans; read the plan.
2. **Read-back beats return values** — the Resolve API can say True and do nothing;
   the server's verification layer and `api_truth` encode that scar tissue.
3. **Render jobs bind to the CURRENT timeline** — pin before mutating; keep render
   timing measurements single-tenant (concurrency inflates them, e.g. 1.2 s → 7.3 s
   under a second agent).
4. **Never restart the serving engine mid-suite** — the agent *is* the engine;
   restarting it ends the session.
5. **Work + scratch off the boot volume** — render outputs, preview renders and
   chooser scratch live on external volumes; the boot disk keeps model weights
   and the engine KV cache. Configure Resolve's cache locations once (see the
   MCP's storage guidance), and pass `EXTERNAL_CACHE` to the launcher for the
   Splash disk cache on a fast external SSD.
6. **Publish-safe by pre-commit scan** — `tools/precommit-scan.sh` refuses content, file
   paths **and commit messages** that would leak home paths, named volumes, camera/reel
   filenames, credential shapes, emails, or client/project names (deny terms live in
   `.git/info/precommit-terms`, never committed). `bash tools/precommit-scan.sh --install`
   wires both hooks; `--all` audits the whole tree. A property description beats a name:
   "8128×4288 HEVC Main 10, 56 min" tells a reader more than a camera-generated filename
   ever did — and if you try to quote such a filename here, the guard refuses the commit.
   A fresh clone does **not** receive the deny list or the hooks: run
   `bash tools/precommit-scan.sh --install` and maintain your own terms in
   `.git/info/precommit-terms` if you want the same scrubbing.
7. **Identity data isn't publishable** — the scan blocks *names*; face geometry and face
   embeddings need the harder rule: never export them at all. Vision probes default to
   boxes + scores + scalar mouth state, write vectors only when you pass `--save-embeddings`,
   and their scratch lives in a per-project directory on a work volume, deleted when the job
   closes. Footage with minors: treat any derived face data as not-for-export.
8. **Grading is read-backs, not claims** — any agent's "done" gets a probe
   (ffprobe / item geometry / pixel diff of rendered frames) before it counts.

## Troubleshooting quick hits

- `No current timeline` on a fresh project → create via `media_pool.create_timeline`.
- MCP behaves like the old version after an update → the running process predates
  the sync; `/mcp` → reconnect **both** servers; proof is the tool count, not the version string.
- Engine not answering → `tail -f ~/Library/Logs/splash/splash.err.log`; first run downloads the model.
- Port 8000 busy → the launcher kills prior instances by pidfile/name; `stop.sh` first.
- Resolve free edition → Workspace ▸ Scripts ▸ `resolve_bridge`; the community server auto-uses it on 21.0.x.
- Vision probe returns 0 faces on a big frame → you're asking a detector to see a 1 % face. Run at native resolution (`--tile auto`), then let stage 2 crop; see the two-stage rule in `vision/README.md`.
- Server's `strata_run(analyzers=['face'])` says it can't run → mediapipe/opencv belong to the *server* venv there: `bash vision/install-vision.sh --mcp-server-venv <server venv>`, then `/mcp` → reconnect.
- Brave MCP connects but every search returns nothing → the key belongs to the **Answers** plan, not **Search** — keys are plan-bound; see `mcp/mcp-config.md`.

**Safe update:** `npx -y davinci-resolve-mcp@latest sync`, then `/mcp` →
reconnect **both** servers. When a major version changed, re-run a benchmark
before trusting the numbers. Never `pip install -U` inside the community
server's venv — it carries its own pins.

**Splash upgrades need a warm-up pass, not just a restart.** A minor Splash bump can reset the
engine's persistent prefix cache (1.7.0 did: `took back 0 restore points … 0 MiB` in the startup
log), which silently depresses every performance number until the cache refills. Re-run the suite
once unscored, then read `/status`: when `cache.cold_misses` stops moving and `hit_rate` is back
above ~0.98, the engine is warm and the next pass is the one you publish.

## Verified stack

Checked current on 2026-11-07 and **re-verified 2026-11-09** by re-running every
command below, so these are versions that were **latest on those days**, not guesses:

Splash 1.6.0 · Qwen3.8-Flash-Next IQ3_S · Claude Code 2.1.319 ·
davinci-resolve-mcp 4.19.3 (Python venv + Node 26.13.0) · brave-search MCP 2.1.4
(opt-in) · DaVinci Resolve Studio
**21.2.0.6** (21.2 shipped 2026-11-04) · Blender 5.2.3 LTS · ffmpeg 9.0.2 ·
whisper.cpp 1.9.5 · macmon 0.11.0 ·
vision add-on on Python 3.12.16 (mediapipe 1.2.2 · opencv + opencv-contrib 5.0.0.93 ·
numpy 2.5.4 — `pip list --outdated` in that venv shows only peripheral packages drifting
(click, scenedetect, tifffile), never the three pins themselves, so the pins are not holding
anything back; OpenCV **5.1.0** is tagged upstream as of 2026-11-06 and **still has no PyPI
wheels** (re-confirmed via `pip index` on 2026-11-09), so 5.0.0.93 remains the newest
installable, and a version-to-version re-measure of the vision numbers belongs with any
future bump) ·
macOS 27.2 arm64 · M5 Ultra 64-core GPU, 96 GB unified.

**2026-11-16 update:** the agent harness switched from Claude Code 2.1.x to **OpenCode
v2.3.0** on benchmark evidence (21/21 outcome + 21/21 honesty + a provably clean seal at
0/745 tool events, $0 vs $34.55 per wave — full reasoning in `HARNESS-MIGRATION.md`), and
the community MCP moved to 5.3.0. The Claude-era versions above are kept as dated history.

**Same day, evening re-check:** the community MCP self-updated to **5.3.1** — #375, a
`prettier` dev-dependency bump in `resolve-advanced`, with no runtime or tool-behaviour
change, so the wave records measured on 5.3.0 still stand. Also re-confirmed that evening:
OpenCode **v2.3.0** is still the newest `v2` tag upstream; Splash **1.6.1** matches brew
stable; the vision venv shows no drift in the three pins; and OpenCV **5.1.0** is *still*
tagged-only on GitHub with no PyPI wheels (`pip index` → newest installable 5.0.0.93).
Resolve **21.2 build 6** (2026-11-04) is also still the newest desktop build, so the local
install is current.
The one caveat worth knowing about a self-updating server: an MCP process that was already
running keeps its pre-update code in memory (check `ps -o lstart` against the install
directory's mtime), so a restart — not just a wait — is what picks up the new version.

**2026-11-17 — Splash 1.6.1 → 1.7.0, and the performance numbers above re-measured.** brew took
1.7.0 the day it shipped; version confirmed by `splash --version` **and** the live
`/opt/homebrew/Cellar/splash/1.7.0/…` process path (`/status` is still schema 8, so the dashboard
is unaffected). **A 1.6.x → 1.7.0 upgrade cold-starts the persistent prefix cache** — the startup
log says it plainly: `took back 0 restore points over 0 KV blocks (0 MiB); left 0 copies behind` —
so the engine suite was run **three passes on one instance behind a recorded warmth gate**
(`cold_misses` frozen at 10 from pass 1 onward, `hit_rate` 0.875 → 0.988, 55.8 GB read back off SSD,
`kv_disk_hit_tokens` 0 → 4.25M). Re-measured: warm TTFT **110–118 ms** (was 159), cold **291 ms**
(was 229 — one sample, flagged as a possible regression, not a finding), ladder w1 **219.8**
(233.2/219.8/207.5 — still the best recorded, though it fell across passes while the plateau held),
plateau **479–494** pooled median 481.6, aggregate peak back at **w4** with the w6 dip deepening to
0.82×, prefill **unchanged** (611,244 tokens in 172.6 s vs 170.5–171.5 s on 1.6.x, so the gain is
decode-side), and the KV probe still clean at 611,244 tokens with **zero** suspensions.

Two operating consequences, not just numbers: **`--verify-rows auto` is now the default** and the
engine states at startup that greedy and seeded output can differ run to run — add
`--verify-rows all` on a fresh `--cache-dir` when a benchmark row has to be reproducible; and
this repo's own sizing table still claimed a **128G** `MAX_CACHE_DISK` default while `start.sh`
has shipped **256G** since the eviction fix — the tables now match the live process
(`--max-cache-disk=274877906944`). Raw JSONL, six `/status` snapshots and the wave's caveats (tenancy was *not*
clean-window — this session shares the engine) are in the benchmarks repo at
`bench/splash-concurrency/results/splash-1.7.0-2026-11-17/`. Unchanged on re-check day: OpenCode
**v2.3.0** still newest, OpenCV **5.1.0.95 still has no PyPI wheels** (`pip index` → newest
installable 5.0.0.93, so the vision pins stand), Resolve **21.2 build 6** still newest desktop build.

**Same day, later — the clean-window pass, and why the engine stays on the stock config.** A
detached runner re-ran the suite with **zero operator-session turns**: ladder w1 **225.2** (best
recorded), plateau 462.9–484.4 (mean 476.8), peak **w4 543.8**, probe decode median 197.4, KV still
0 suspensions / 0 demotions at 611,244 tokens. The tenancy-free pass confirms the shape and nudges
the latency cells; it does not lift the plateau. The `--verify-rows` question was measured rather
than assumed: the same greedy request ×5 under `auto` and under `all` produced **one distinct output
in both configs** (same hash), decode price **−0.2 %** — determinism is free *within this probe*
(n=5, one short prompt, hashes cover content + reasoning), so there is no performance case for
`all` and no reason to leave the stock config. A side probe also priced the effort knob: per-request
`reasoning_effort` is honored, and on one bounded Resolve-arithmetic task **low/medium stopped
thinking on their own** (1,771 / 2,320 reasoning tokens, correct answers, 16–20 s) while **xhigh
consumed the entire 16k thinking budget** (16,385 tokens, 107 s) for the same answer — ~6× for
nothing measurable there. **Daily config therefore still stays exactly as `start.sh`
ships it** (256G cache disk, 56G memory, expert-memory auto, xhigh effort, 16k thinking budget,
persistent cache, `--verify-rows auto`), re-proven after the runs from the engine's own startup
banner and `/status` (which now carries a `verify_rows` field): the 21/21 agentic evidence was
earned at xhigh, so moving the default needs the proper test — an A/B of `medium` vs `xhigh` across
the six agentic briefs — not one bounded task. Two harness lessons came out of the
same runs and both are now rules: **stopping Splash means killing the supervisor**
(`… -m server.server` — `pkill -f "splash serve"` only kills the child, which respawns with the
original args; `splash` has no `stop` subcommand), and **grading must read payloads, not trust
fields** — a determinism probe that hashed `message.content` alone returned ten identical hashes of
an empty string while the model's output lived in `reasoning_content`. Records:
`bench/splash-concurrency/results/clean-verifyrows-2026-11-17/` (incl. `VALIDITY.md`) and
`…/clean-verifyrows-2026-11-17-pass2/` in the benchmarks repo.

**2026-11-17 — that A/B ran the same day (42 sealed sessions, both arms).** Effort was varied
*without touching the engine*: OpenCode sends no `reasoning_effort` field at all, so both arms
rode logging proxies (passthrough on :8010 = the daily xhigh default; :8011 injects
`reasoning_effort:"medium"` per request), and the proxy audit proves the injection per session
(port attribution — 0 unproven across 42). **Both arms scored 16/18** on the seven-brief suite.
xhigh paid ~3× median thinking tokens (10,538 vs 3,609; totals 216k vs 100k) and ~40% more wall
time for nothing measured; medium's cost showed up as tool-call sloppiness instead (50
harness-rejected mangled tool names vs 3). The engine's daily config still stays as `start.sh`
ships it — that's now a preference, not something the suite's evidence argues for: on agentic
Resolve work the measurement says medium is the better default, and two medium-arm failures came
from an operator fixture-design flaw (a two-project current-project race) that is recorded in the
wave's `VALIDITY.md` rather than smoothed over. Three method upgrades shipped with it: T1 honesty
grading now fails closed on operator-extracted reported values; the wave's tool-census proved the
seal held (nothing outside the allowed MCP trio executed in 42 sessions) and reclassified the
noisy `seal_leaks` field; and T8's Fusion-comp read-backs proved attached comps do **not** survive
project close/load churn even without a restart — same in-wave-vs-post-wave split the 16f wave hit,
now with the actual mechanism. Records: `bench/resolve-agentic/results/2026-11-17g-effort-ab-wave/`
and `bench/resolve-agentic/results-2026-11-17g.json`.

**2026-11-17 — the operator acted on that A/B: the daily thinking default moved `xhigh` → `medium`.**
`start.sh` now reads `REASONING_EFFORT="${REASONING_EFFORT:-medium}"`, so the config is still one
line in one file, and the way to go deeper for a single launch is a flag rather than an edit:
`start.sh --xhigh` (also `--low` / `--high` / `--effort=<value>`, and an invalid value stops the
launch instead of reaching the engine). Worth being precise about what the knob governs, because the
engine log settled an earlier guess: **OpenCode sends no `reasoning_effort` at all**, so the daily
default *is* what this chat gets — the banner records it as `effort absent → medium`, and the same
line read `→ xhigh` before the flip. Per-request `reasoning_effort` from an API caller still
overrides the default, which is how the A/B arms were run without restarting anything. Proof the
live engine carries the new value comes from the startup banner and the supervisor's own argument
list (`--default-reasoning-effort=medium`), not from the script on disk: `start.sh` edits only take
effect at the next launch, and stopping cleanly means killing the supervisor
(`… -m server.server`), which `stop.sh` now does too — killing the `splash serve` child alone leaves
a supervisor respawning children with the *old* args.

**2026-11-17, evening — the OpenCV watch fired: 5.1.0.95 wheels landed, the vision stack moved
and was re-measured.** Earlier re-check lines today read "5.1.0.95 still has no PyPI wheels";
PyPI received 5.1.0.95 that same day — Windows 14:37 UTC, macOS arm64 (`cp37-abi3-macosx_15_0`)
at 17:40 UTC, ~5 h behind the GitHub tag. `opencv-python` and `opencv-contrib-python` moved to
**5.1.0.95 together** in one `--only-binary :all:` transaction (the never-upgrade-one-alone rule;
the never-compile-an-sdist rule), numpy came along at 2.5.5, and the import chain was re-verified
before use (cv2 5.1.0, mediapipe 1.2.3, scenedetect 0.7.3, pedalboard 0.9.26). Re-measure
(benchmarks `bench/visual-venv` run5, SHA-identical fixtures): **median ×0.853 across all 48
detect rows** — canonical 4×3@0.5 **0.283 → 0.227 s**, 2×2 ×0.65 but 8×4 ×0.99, i.e. the win
sits in detector create/init, not raw inference; `import cv2` 0.157→0.036 s; cold process
(import→91 faces) 1.49→1.37 s. The shipped `face_probe.py` and `compare/` were re-run per the
vision README's own rule: 91 faces, detect+embed 0.94–0.97 s, landmarks 82/91, merge shape held
(1.8% vs 2.0%). Two behavioural findings change the guidance. **(1) The `match()` in-place vector
rewrite is NOT fixed in the 5.1.0.95 wheels** — the upstream fix merged 2026-08-28 did not ship
in the release; the probe reproduces bit-identically (norms 9.82/12.40 → 1.00/1.00), and
vision/README rule 4 now says don't wait for a release to fix it. **(2) The bundled FFmpeg 9.0.2
decodes H.264 differently** — same fixture, different first-frame pixels (sha `6716af2b…` on
5.0.0.93 vs `a2bebe5f…` on 5.1.0.95, proven with an isolated wheel), which moved 9 of the 48
bench H.264 face-count rows by ±1 while every PNG row and the cosine stats stayed bit-identical:
the detector is unchanged, decoder-version drift is real, so H.264 face counts are
decoder-version-dependent records. Also confirmed: `readNetFromTensorflow` is gone (as predicted),
and every `FaceDetectorYN/SF.create()` now emits a `setPreferableTarget` stderr warning —
silence it via `cv2.utils.logging.setLogLevel` in stderr-capturing pipelines. Records:
`bench/visual-venv/run5.json` (+ `run5.err`, + the long-deferred key-label fix), benchmarks
`f700fc7`.

**2026-11-17, evening — routine version sweep, and what is NOT moving.** `brew outdated` came
back with two runtime-dependency patches only: **dav1d 1.5.4→1.5.5** (behind ffmpeg) and
**libomp 23.1.5→23.1.6** (behind ggml/llama.cpp/whisper.cpp); upgraded, dependents relinked
clean. The tracked stack is current: Splash **1.7.0** = brew stable, node **26.13.1_2**,
opencode **v2.3.0** = newest upstream `v2` tag (verified against `git ls-remote --tags`),
community MCP **5.3.1** = npm latest, whisper.cpp 1.9.5, ffmpeg 9.0.2 — none outdated.
The one npm move: the pinned **brave-search MCP 2.1.4 → 2.1.5** (published 2026-11-17),
release notes are dependabot dependency bumps plus `fix: accept el and ja for search_lang` —
no tool-surface change, so the search results in the wave records are unaffected; remember a
*running* MCP process keeps the old code until reconnected, the pin only binds the next launch.
And **why npm itself stays on 11.20.0 despite 12.2.2 being current upstream**: npm 11.20.0 is a
file *inside* brew's node formula (`/opt/homebrew/bin/npm` → `Cellar/node/…`), and the standalone
`npm` formula is gone — it's just a node alias now. The only way to npm 12 today is
`npm install -g npm@12`, which overwrites a brew-owned symlink: disk-npm would stop matching what
the installer accounts for, and the next `brew upgrade node` would silently revert it — the same
version-on-disk ≠ version-running trap flagged above, on the launch transport (npx) of the pinned
MCP trio. Nothing here needs npm 12 (its breaking changes — `shrinkwrap`, `adduser`/`stars`
removal, `--json` output shapes — touch surfaces this stack never calls), so npm 12 arrives the
clean way: with the next node release that bundles it, in one brew-managed step.

```bash
# re-check in about a minute, without changing anything
brew outdated --verbose                                   # formulae behind
~/resolve-vision-venv312/bin/pip list --outdated          # vision pins
# source releases can outrun the wheels that install them:
~/resolve-vision-venv312/bin/pip index versions opencv-contrib-python
npm view @brave/brave-search-mcp-server version           # npx-run servers
# and inside a session: resolve_control(action='mcp_update_status', params={force_check:true})
```

One thing **not** to blanket-upgrade: the community server's own venv carries its
dependencies (it pins the `mcp` SDK at 1.30.0 while SDK 2.x exists upstream). A
`pip install -U` across that venv can break a working server. Update it with the
upstream path only — `npx -y davinci-resolve-mcp@latest sync` — then reconnect both servers.

The 2026-11-09 re-check caught upstream already ahead: **davinci-resolve-mcp 5.0.3** (major
bump past 4.19.3) carries two security fixes to the analysis panel — its folder picker and
Claude Code terminal launcher used to interpolate paths/commands into AppleScript source —
with no breaking changes declared. This workstation was still on 4.19.3 on the re-check day;
a major bump gets the usual treatment: sync, reconnect, rerun the benchmark suite, then
update the numbers here.

## Versioning

This repo is semver from **v2.0.0** — the OpenCode harness switch:

- **Major** — a breaking change to the stack contract: harness swap, install/start/stop
  semantics, or config-shape requirements. The Claude Code era was untagged (think of it
  as v1.x); v2.0.0 is the OpenCode era. The reasoning for breaking changes lives in
  `HARNESS-MIGRATION.md`.
- **Minor** — new scripts, flags, or add-ons that change nothing existing (the `--lsp`
  leg would have been one).
- **Patch** — fixes and documentation only.

Releases are tagged on `main` and published on GitHub Releases with a short
"what breaks / what changed" note. Not every commit lands in a release — tag when the
tagged state is worth pointing someone at.

## License

Scripts in this repo: MIT (see `LICENSE`). The tools it installs have their own
licenses — Splash (incoai), davinci-resolve-mcp (MIT, samuelgursky),
brave-search-mcp-server (MIT, Brave), splash-dashboard (rickhuizinga),
Blender (GPL), OpenCode (MIT, sst), opencode-v2-lsp-support (community, MIT).

The **vision add-on's** model weights, read from the `LICENSE` file in each source directory:
OpenCV **YuNet** (detector) is **MIT**, and **SFace** (recogniser) is **Apache-2.0** — both stated
as covering all files in their OpenCV Zoo model directories, and both classes already ship inside
the `opencv-contrib-python` this add-on installs, so there is no extra dependency and nothing
downloads itself at run time. One item still worth checking before a paid job: MediaPipe's *code*
is Apache-2.0, but the hosted `.task`/`.tflite` model pages I downloaded from carry **no licence
line**. If you add any other model to this stack, read its weights' licence rather than the
library's — that is the distinction that matters commercially.
