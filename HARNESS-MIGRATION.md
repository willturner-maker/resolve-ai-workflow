# Harness migration: Claude Code → OpenCode (2026-11-16)

This stack was built around Claude Code driving the same local Splash engine through the
`splash claude` bridge. On **2026-11-16** that harness was removed from this machine and
replaced by **OpenCode** talking to Splash through its OpenAI-compatible endpoint. This
document records why — the decision is benchmark-measured, not preference.

## The measurement

The resolve-agentic benchmark (repo: [willturner-maker/benchmarks](https://github.com/willturner-maker/benchmarks),
`bench/resolve-agentic/`) ran the same seven-task family (T1/T2/T3/T7/T8 smoke+hard, F1/F2
frontier pair) × 3 trials each, same model (`Qwen3.8-Flash-Next IQ3_S` on a local Splash
engine at `127.0.0.1:8000`), same Resolve MCP trio, graded fail-closed against a
pre-dispatch, hash-sealed ground truth.

| | Claude Code 2.1.325 (wave 2026-11-16) | OpenCode v2.3.0 (wave 2026-11-16f) |
|---|---|---|
| Outcome | 21/21 (hard 15/15) | 21/21 (hard 15/15) |
| Honesty (claims = read-backs) | 21/21 | 21/21 |
| Seal audit (non-MCP tool events) | 0 / 585 | 0 / 745 |
| Wave wall | 4,983 s | 3,743 s (−25%) |
| Turns | 711 | 403 (−38%) |
| Cost | $34.55 | $0 |

Outcome is a statistical tie (Wilson 95% hard set: [79.6, 100] vs [78.6, 100]) — the case
for the switch is **not** capability. It is:

1. **The last differentiator fell.** The November verdict kept Claude for one reason:
   *"pick Claude Code when the seal must be watertight."* OpenCode 1.19.5 had leaked benign
   tool calls in 3 of 3 waves. OpenCode V2's `policies` layer (hard denials, live-probed)
   sealed 21/21 trials with zero leaks — the instrument is now equal or better.
2. **Cost asymmetry at equal results.** $34.55 per wave vs $0, with the same outcome, the
   same honesty record, 25% less wall, 38% fewer turns, and ~10× fewer generated tokens.
3. **Locality.** No egress of client media metadata; the driver, the model, and the media
   stay on one machine — the point of this workstation.

## What changed on the machine

- OpenCode installed (`curl -fsSL https://opencode.ai/install`); Splash provider written in
  **V2 config shape** (`providers.<name>.{package,settings,models}`, `mcp.servers`).
- Community Resolve MCP registered via `npx -y davinci-resolve-mcp@latest setup --clients opencode`;
  official ResolveMCP via `opencode mcp add --global "DaVinci Resolve" -- <app path>`.
- LSP capability (V2 ships none) restored **project-scoped** by the community plugin
  `christensenjairus/opencode-v2-lsp-support` — deliberately not global, so sealed/agent
  pools stay provably plugin-free.
- Claude Code fully removed (binary, its home state directory and top-level config file,
  app-support/cache/storage residue, ~2.4 GB); configs archived off-repo at mode 600 before deletion.
- `start.sh` / `stop.sh`: the `splash claude` bridge legs replaced by a plain `exec opencode`
  handoff and an interactive-session note.

## Tripwires (what would reinstate the old driver path)

- Any future wave with a non-MCP tool event in the seal audit (audit is cheap: every
  `tool_use` must match the Resolve MCP prefix — the driver fails closed on any miss).
- An outcome cliff on a new fixture family that a reference (API-model) harness passes.
- An honesty break (final table ≠ read-backs) at more than 1/21 trials.

The Claude reference wave's data stays banked in the benchmarks repo (grading, walls, costs,
sealed ground truth `sha256 4c426344…`) — the calibration axis survives as archived data,
which is exactly why the binary no longer needs to live here.

## Pointers

- Wave findings: `bench/resolve-agentic/FINDINGS-2026-11-16.md`, `FINDINGS-2026-11-16f.md`
- Seal mechanism (10-probe battery): `bench/resolve-agentic/SEAL-V2-2026-11-16.md`
- Published analysis: *The Local Ceiling* (wave-16f writeup, on the operator's publishing volume)
