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
│      ▼                                                                                    │
│  DaVinci Resolve Studio 21.2  ←── EXR title sequences rendered by headless Blender        │
│      ▲                                       (Cycles on Metal, film_transparent)          │
│      └── ffmpeg/ffprobe — QC read-backs, sequence encoding, frame extraction              │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

## What each piece brings

| Tool | Benefit |
|---|---|
| **Splash** ([incoai/tap](https://github.com/incoai/splash), brew) | Local LLM engine serving `Qwen3.8-Flash-Next IQ3_S` (262k context, GGUF/IQ3 quant) behind OpenAI *and* Anthropic-compatible APIs. Persistent disk prefix-cache means fresh agent sessions reuse ~20–45k cached tokens each. TTFT ~200 ms warm; single-stream decode ~170 tok/s; aggregate plateau ~375 tok/s under concurrency. Also hosts a built-in chat UI on :8000. |
| **Claude Code via `splash claude`** | The agentic operator. Reads the timeline, plans edits, executes them through MCP with dry-run/confirm-token discipline, verifies via read-backs, renders, grades its own output with ffprobe. Nothing leaves the machine. |
| **Community `davinci-resolve` MCP** ([samuelgursky/davinci-resolve-mcp](https://github.com/samuelgursky/davinci-resolve-mcp)) | The hands: ~36 action-dispatch tools over the whole scripting API — media pool, timelines, ripple edits with dry-run plans, markers, Fusion comps, render queue + **verified outputs** (ffprobe cross-check of every render), and a live `api_truth` knowledge base of verified Resolve API quirks. Destructive ops auto-archive timelines first. |
| **`davinci-resolve-advanced` MCP** (same project) | The forensic layer: closed-`Project.db` reads/writes (captions, speed ramps), `.drx` grade XML, DRT timelines, FCPXML/EDL/AAF conform, deliverable-QC specs — all without Resolve running. |
| **Official ResolveMCP** (bundled in Resolve Studio 21.1+) | Blackmagic's own 18-tool surface: canonical and versioned with the app; useful cross-check and fallback. |
| **splash-dashboard** ([rickhuizinga/splash-dashboard](https://github.com/rickhuizinga/splash-dashboard)) | Live engine observability on :8280: KV residency, prefix-cache hit rate, admission pacing, decode batch widths — the instrument panel that turns "the model feels slow" into numbers. |
| **Blender (LTS, at `/Applications`)** | Content forge: 3D title stings, extruded logos, generated media — scripted headless (`--background --python`), rendered transparent-EXR, imported into Resolve as sequence clips with straight alpha. See [`blender/`](blender/). |
| **ffmpeg / ffprobe** (brew) | The verification layer: every render gets probed (frame count, codecs, duration) before it's trusted; sequence encoding; frame extraction for visual checks. |
| **whisper.cpp / whisper CLI** (brew + MCP-integrated) | Local transcription; the MCP server also feeds transcripts into timeline subtitle tracks and cut-candidate proposals. |
| **macmon** (brew) | Zero-overhead Apple GPU/memory/ANE telemetry in a second terminal — watch unified-memory pressure while Resolve renders and the engine serves, which is how the 56 GB memory budget below was chosen. |

## Quick start

**Requirements**

- Apple Silicon Mac, ideally ≥48 GB unified memory (tuned here on 96 GB;
  the engine prints its own recommended working set on smaller ones).
- **DaVinci Resolve Studio** (external scripting is Studio-only; the free
  edition reaches the community server via the in-app bridge on 21.0.x).
- macOS with Homebrew; Python 3.11+; Node 20+.

```bash
git clone https://github.com/willturner-maker/resolve-ai-workflow.git
cd resolve-ai-workflow
bash install.sh            # everything below, wired into Claude Code
start-resolve-ai.sh        # Splash → dashboard → Resolve → Claude Code (one command)
stop-resolve-ai.sh         # clean shutdown (leaves Resolve alone)
```

First start downloads the model (tens of GB) into Splash's cache; after that it's
seconds. The launcher's memory numbers are tunable without editing:

```bash
MAX_MEMORY=32G MAX_CACHE_DISK=64G EXTERNAL_CACHE="/Volumes/YourSSD/splash-cache" start-resolve-ai.sh
```

- `start.sh` / `stop.sh` — the exact scripts this workstation runs (with the
  memory-tuning log in the header comments: why 56 GB working set / 128 GB disk
  cache on a 96 GB machine next to a running Resolve).
- `mcp/mcp-config.md` — how the three MCP servers are registered, verified and
  updated, and why all three are kept side by side.
- `blender/` — the title pipeline: `exr_title_demo.py` + a README of every
  Blender 5.x gotcha and the Resolve import specifics (multi-path EXR import,
  Alpha mode → Straight, end-exclusive append frames, proof-render verification).

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
7. **Grading is read-backs, not claims** — any agent's "done" gets a probe
   (ffprobe / item geometry / pixel diff of rendered frames) before it counts.

## Troubleshooting quick hits

- `No current timeline` on a fresh project → create via `media_pool.create_timeline`.
- MCP behaves like the old version after an update → the running process predates
  the sync; `/mcp` → reconnect **both** servers; proof is the tool count, not the version string.
- Engine not answering → `tail -f ~/Library/Logs/splash/splash.err.log`; first run downloads the model.
- Port 8000 busy → the launcher kills prior instances by pidfile/name; `stop-resolve-ai.sh` first.
- Resolve free edition → Workspace ▸ Scripts ▸ `resolve_bridge`; the community server auto-uses it on 21.0.x.

## Verified stack

Splash 1.6.0 · Qwen3.8-Flash-Next IQ3_S · Claude Code (native installer) ·
davinci-resolve-mcp 4.19.2 (Python venv + Node 26) · DaVinci Resolve Studio
21.2.0.6 · Blender 5.2.3 LTS · ffmpeg 9.0.2 · whisper.cpp · macmon ·
macOS 27.2 arm64 · M5 Ultra 64-core GPU, 96 GB unified.

## License

Scripts in this repo: MIT (see `LICENSE`). The tools it installs have their own
licenses — Splash (incoai), davinci-resolve-mcp (MIT, samuelgursky),
splash-dashboard (rickhuizinga), Blender (GPL), Claude Code (Anthropic).
