# The three DaVinci Resolve MCP servers

The workstation registers three servers side by side. They are complementary —
Claude Code routes between them per task, and having all three is what makes the
workflow feel like one operator with hands on every layer of Resolve.

## 1. `davinci-resolve` — community server (Python)

- Repo: https://github.com/samuelgursky/davinci-resolve-mcp (MIT)
- Install (one-shot): `npx -y davinci-resolve-mcp@latest setup --clients claude-code`
  → managed tree under `~/Library/Application Support/davinci-resolve-mcp`
  (own venv; marker file `.davinci-resolve-mcp-managed.json` holds the version).
- Surface: ~36 *compound, action-dispatch* tools (`timeline`, `timeline_item`,
  `render`, `media_pool`, `project_manager`, `fusion_comp`, `markers`, …) plus
  `media_analysis` and `resolve_control`.
- Why it's the workhorse:
  - **Safety rails**: dry-run defaults on destructive edits, confirm-token gates,
    automatic timeline versioning/archiving before mutations, read-back
    verification ("did the API lie?") on every mutation.
  - **`api_truth` knowledge base**: behaviorally-verified quirks of the Resolve
    scripting API per build — e.g. that `SetProperty` returns True but the render
    ignores it under Inspector keyframes. This is institutional memory, queried live.
  - **Guarded renders**: `prepare_render_job` + `verify_output` cross-check the
    actual file (ffprobe) against the job metadata, catching "Complete but empty"
    renders that the API reports as success.

## 2. `davinci-resolve-advanced` — same project, Node side

- Same installer; Node 20+ (`brew install node`).
- Offline/analysis tools that don't need Resolve running: read/write `Project.db`,
  `.drx` grade XML, DRT timelines, Fusion toolsets, conform (FCPXML/EDL/AAF),
  deliverable QC against ffprobe specs.
- Practical benefit: closed-project surgery (DB-level caption writes, speed ramps,
  media relink forensics) and QC of finished renders without touching the live app.

## 3. `DaVinci Resolve` — official Blackmagic ResolveMCP

- Ships **inside Resolve Studio 21.1+** at
  `/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Applications/ResolveMCP`
  — registered with `claude mcp add "DaVinci Resolve" -- <path>`.
- 18 tools versioned with the Resolve app; canonical scripting surface, and the
  one Blackmagic supports as the app evolves.
- Note: external scripting is Studio-only (free edition reaches the in-app bridge).

## Registering / verifying

```bash
claude mcp list                       # expect all three names
# In a Claude Code session:
/mcp                                  # reconnect servers after any update
```

Gotcha learned the hard way: after an update, the **version field can report the
on-disk version while the connected process still runs old code**. Proof of a real
reconnect is the tool count/shape changing, not the version string.

## Updating

```bash
npx -y davinci-resolve-mcp@latest sync     # refreshes Python + Node servers in place
# then: /mcp → reconnect BOTH davinci-resolve and davinci-resolve-advanced
```

Ask the server whether it's behind before syncing — no Resolve connection needed, and it
reads the same release feed the installer uses:
`resolve_control(action='mcp_update_status', params={force_check: true})`.

Don't shortcut the sync by upgrading that venv's dependencies by hand. It carries the
server's own pins — at time of writing it runs the `mcp` SDK at 1.30.0 while SDK 2.x is
current upstream, alongside its torch/transformers stack — and a blanket `pip install -U`
in there is the fastest way to break a server that was working. If the sync path fails,
fix the sync.

## Permissions

The community server deliberately defaults destructive actions to dry-run and
gates the rest behind confirm tokens, so auto-approving its tools is reasonable.
`~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "mcp__davinci-resolve__*",
      "mcp__davinci-resolve-advanced__*",
      "mcp__DaVinci_Resolve__*"
    ]
  }
}
```

Adjust to taste; keeping plan/dry-run calls visible before executing mutations is
the practice that keeps an autonomous session trustworthy.
