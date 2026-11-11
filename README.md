> **Disclaimer**
>
> This content describes a method for running a local large language model (LLM) on a Mac Studio in conjunction with DaVinci Resolve Studio version 21.1 or later. It is provided for informational purposes only and does not constitute a guarantee of suitability, performance, or fitness for any particular purpose. Nothing herein should be construed as a recommendation to purchase any specific hardware, including an M5 Ultra Mac Studio or any other model.
>
> The author assumes no responsibility or liability for any decisions made based on this information, including any purchase of hardware, or for any resulting costs, performance shortfalls, or other consequences. Users are solely responsible for independently evaluating their own requirements and determining the adequacy of any hardware or software configuration for their intended use.
>
> This stack is independent of Blackmagic Design, Inco AI, and Anthropic; those names appear only because the tools are used.

# DaVinci Resolve + Local AI Workstation

A complete, scripted post-production workstation: **Claude Code driven by a
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
│  Claude Code  (splash claude — the agent IS the model you run locally)                    │
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
- [Benchmarks (measured, reproducible, honest)](#benchmarks-measured-reproducible-honest)
- [Operating practices that keep it trustworthy](#operating-practices-that-keep-it-trustworthy)
- [Troubleshooting quick hits](#troubleshooting-quick-hits)
- [Verified stack](#verified-stack)
- [License](#license)

## What each piece brings

| Tool | Benefit |
|---|---|
| **Splash** ([incoai/tap](https://github.com/incoai/splash), brew) | Local LLM engine serving `Qwen3.8-Flash-Next IQ3_S` (262k context, GGUF/IQ3 quant) behind OpenAI *and* Anthropic-compatible APIs. Persistent disk prefix-cache means fresh agent sessions reuse ~20–45k cached tokens each. TTFT ~200 ms warm; single-stream decode ~170 tok/s; aggregate plateau ~375 tok/s under concurrency. Also hosts a built-in chat UI on :8000. |
| **Claude Code via `splash claude`** | The agentic operator. Reads the timeline, plans edits, executes them through MCP with dry-run/confirm-token discipline, verifies via read-backs, renders, grades its own output with ffprobe. Nothing leaves the machine. |
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
- macOS with Homebrew; Python 3.11+; Node 20+.
- Optional Blender LTS: `brew install --cask blender` (or download from
  blender.org). `install.sh` checks for it and prints this hint, but never
  installs it itself.

```bash
git clone https://github.com/willturner-maker/resolve-ai-workflow.git
cd resolve-ai-workflow
bash install.sh            # everything below, wired into Claude Code
bash install.sh --vision   # same, plus the opt-in face/mouth layer (vision/README.md)

# After install, open a NEW terminal — the launchers arrive on PATH as:
start-resolve-ai.sh        # Splash → dashboard → metrics (opt) → Resolve → Claude Code
stop-resolve-ai.sh         # clean shutdown (leaves Resolve alone)

# From the clone, without relying on PATH:
bash start.sh
bash stop.sh
```

> **First start:** the model download is tens of GB and can take several
> minutes; subsequent starts take seconds. Watch the terminal until the
> dashboard URL appears and Claude Code opens.

> **Disk:** the model itself is a one-time download. The persistent prefix
> cache can grow up to `MAX_CACHE_DISK` (default 128 G). An external SSD is
> recommended for the cache — see the `EXTERNAL_CACHE` variable in `start.sh`.

### First-run checklist

1. `bash install.sh` finishes and prints the registered MCP servers
   (the three Resolve names — plus `brave-search` if you opted in).
2. Open a **new** terminal so PATH picks up the launchers.
3. `start-resolve-ai.sh` — first start downloads the model; later starts
   begin in seconds.
4. The dashboard comes up on :8280, Resolve launches, then Claude Code opens.
5. Inside Claude Code: `/mcp` → confirm the three Resolve servers are connected.
6. Optional: `macmon` in a second terminal to watch unified-memory pressure.
7. Confirm the MCP path with a read-only probe — in Claude Code ask:
   `List the timelines in the current Resolve project (read-only)`. A reply
   naming your timelines means the whole chain (engine → MCP → Resolve) works.

**If the engine never becomes ready:** `tail ~/Library/Logs/splash/splash.err.log`
(the dashboard leg logs to `~/splash-dashboard.log`).
**If MCP servers are missing:** re-run `npx -y davinci-resolve-mcp@latest setup
--clients claude-code`, then `/mcp` to reconnect.
**If memory pressure turns red:** lower `MAX_MEMORY` and restart (sizing table below).

First start downloads the model (tens of GB) into Splash's cache and can take
several minutes. Subsequent starts are seconds once the weights are cached.

The launcher's memory numbers are tunable without editing the script. Defaults
are sized for a 96 GB machine running Resolve concurrently; smaller machines
should lower them (see table below).

```bash
# example for a 64 GB machine
MAX_MEMORY=32G MAX_CACHE_DISK=64G start-resolve-ai.sh

# or with the prefix cache on a fast external SSD
MAX_MEMORY=56G MAX_CACHE_DISK=128G EXTERNAL_CACHE="/Volumes/YourSSD/splash-cache" start-resolve-ai.sh
```

**Suggested starting points by machine size** (the engine also prints its own
recommended working set at startup):

| Unified memory | Suggested `MAX_MEMORY` | Suggested `MAX_CACHE_DISK` | Notes |
|---|---|---|---|
| 96 GB | 56G (default) | 128G (default) | Measured on M5 Ultra + Resolve |
| 64 GB | 32–40G | 64G | Leave headroom for Resolve |
| 48 GB | 24–28G | 32–64G | Watch system pressure; engine recommendation is authoritative |

Rough disk use on first run:

- Model weights (Splash cache): tens of GB (one-time download)
- Persistent prefix cache: up to the `MAX_CACHE_DISK` value (default 128G; lives under `~/Library/Caches/Splash/` unless `EXTERNAL_CACHE` points elsewhere)
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
- **Engine**: TTFT 201 ms warm / 380 ms cold; decode plateau ~375 tok/s from
  width 4 through 32 (2.5× single stream — a wall, not a cliff); KV admission
  paces gracefully at 4.4× the resident KV budget without a single suspension.

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
- Port 8000 busy → the launcher kills prior instances by pidfile/name; `stop-resolve-ai.sh` first.
- Resolve free edition → Workspace ▸ Scripts ▸ `resolve_bridge`; the community server auto-uses it on 21.0.x.
- Vision probe returns 0 faces on a big frame → you're asking a detector to see a 1 % face. Run at native resolution (`--tile auto`), then let stage 2 crop; see the two-stage rule in `vision/README.md`.
- Server's `strata_run(analyzers=['face'])` says it can't run → mediapipe/opencv belong to the *server* venv there: `bash vision/install-vision.sh --mcp-server-venv <server venv>`, then `/mcp` → reconnect.
- Brave MCP connects but every search returns nothing → the key belongs to the **Answers** plan, not **Search** — keys are plan-bound; see `mcp/mcp-config.md`.

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

## License

Scripts in this repo: MIT (see `LICENSE`). The tools it installs have their own
licenses — Splash (incoai), davinci-resolve-mcp (MIT, samuelgursky),
brave-search-mcp-server (MIT, Brave), splash-dashboard (rickhuizinga),
Blender (GPL), Claude Code (Anthropic).

The **vision add-on's** model weights, read from the `LICENSE` file in each source directory:
OpenCV **YuNet** (detector) is **MIT**, and **SFace** (recogniser) is **Apache-2.0** — both stated
as covering all files in their OpenCV Zoo model directories, and both classes already ship inside
the `opencv-contrib-python` this add-on installs, so there is no extra dependency and nothing
downloads itself at run time. One item still worth checking before a paid job: MediaPipe's *code*
is Apache-2.0, but the hosted `.task`/`.tflite` model pages I downloaded from carry **no licence
line**. If you add any other model to this stack, read its weights' licence rather than the
library's — that is the distinction that matters commercially.
