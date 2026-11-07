# The MCP servers on this workstation

The workstation registers three Resolve servers side by side. They are
complementary — Claude Code routes between them per task, and having all three is
what makes the workflow feel like one operator with hands on every layer of
Resolve. At the end sits one optional non-Resolve companion (`brave-search`),
the only leg that costs money and leaves the machine.

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

## Optional companion: `brave-search` — official Brave Search MCP

Not a Resolve server — the research leg. It buys the agent the ability to
fact-check live things no model can know: whether a new Resolve build changed an
API behaviour the scripting docs don't mention, whether an upstream release is
installable yet (tag on GitHub ≠ wheels on PyPI — that gap is real and this repo
depends on both), what a vendor actually shipped in a version. WebFetch reads a
page once you have a URL; this is what finds the URL. Every "verified stack"
claim in the README was checked through a route like it.

- Package: `@brave/brave-search-mcp-server` (MIT, by Brave) —
  https://github.com/brave/brave-search-mcp-server — run via npx, pinned like
  everything else here.
- Register (user scope; the key goes into the MCP env entry, not shell history):

  ```bash
  claude mcp add --scope user brave-search -e BRAVE_API_KEY='<your-key>' \
    -- npx -y @brave/brave-search-mcp-server@2.1.4
  ```

- **Requirements — the paid part** (prices read from Brave's own pricing page,
  2026-11-07; verify before quoting them onward):
  - Sign up at https://api-dashboard.search.brave.com and subscribe to the
    **Search** plan. A card is required even for free use (Brave calls it
    anti-fraud); billing is **prepaid credits, not a subscription** — nothing is
    charged while you're drawing on the free credit.
  - **$5 per 1,000 requests**, 50 req/s capacity, and every plan carries **$5 of
    free credit applied automatically each month** — about 1,000 queries a month
    at no cost, which is plenty for an agent that searches deliberately rather
    than reflexively. (The old 2,000-queries/month free plan no longer exists.)
  - **Keys are bound to a plan, and Search vs Answers are separate
    subscriptions.** The MCP server calls the raw web/news/image/video endpoints,
    which need a *Search*-plan key. An *Answers*-plan key connects fine and
    answers with **empty** result envelopes. "Server works but every search
    returns nothing" = wrong plan's key. That one cost an afternoon here.
  - If you script against the API directly instead: Brave authenticates with the
    `X-Subscription-Token` header, not `Authorization: Bearer`.
- Privacy: this is the one server where queries leave the machine. Keep client
  names, reel names and footage metadata out of search strings for the same
  reason the pre-commit scan keeps them out of commit messages — describe
  properties, never quote identifiers.

## Registering / verifying

```bash
claude mcp list                       # expect the three Resolve names (+ brave-search if opted in)
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
