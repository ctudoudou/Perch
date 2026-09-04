<div align="center">

<img src="docs/images/icon.png" width="120" alt="Perch">

# Perch

**Your coding agents, perched on the notch.**

Claude Code and Codex, at a glance — who's working, who's waiting for you,
and how much of your quota is left.

[繁體中文](docs/README.zh-TW.md) · macOS 14+ · MIT

<img src="docs/images/collapsed.png" width="420" alt="The collapsed state hugging the notch">

</div>

---

## What it does

Two small clusters hug the physical notch, leaving the cutout itself clear. A
pulsing dot and a count on the left; a tinted badge per tool on the right,
dimmed when idle and dotted when something needs you.

Point at it and the panel drops down.

<img src="docs/images/tasks.png" width="620" alt="The Tasks panel">

Every session with its state, project, branch, context gauge and the last few
turns. Click a row to expand it; click the arrow to jump straight to the app.

The hover target is the notch strip and those clusters — **not** the whole
window — so pointing anywhere near the middle of the screen does nothing.

## Usage and quota

<img src="docs/images/usage.png" width="620" alt="The Usage panel">

Spend per tool, and every quota bucket the account holds — with reset
countdowns. Codex publishes a general allowance alongside per-model ones, so
each is labelled: a model bucket sitting at 0% says nothing about the general
one.

Numbers come from the tools themselves. Where a reading can't refresh itself,
it's captioned with its age rather than passed off as current.

## Stats

<img src="docs/images/stats.png" width="620" alt="The Stats panel">

Sessions, messages, tokens, active days, streaks, peak hour and top model, over
all time, 30 days or 7. A **Models** view breaks the same range down by model
with stacked daily bars.

---

## Install

```bash
./build-app.sh release
open build/Perch.app
```

Perch is an accessory app — no Dock icon. Everything lives in the menu bar item
and the notch. To run it at login, add `build/Perch.app` under
System Settings → General → Login Items.

## Live reporting

Perch can read log files, or the tools can **tell it what happened**. The second
is better: a file's modification time can't distinguish a model that is thinking
from one that finished thirty seconds ago, while a lifecycle event fires *at*
the transition and says which one it was.

Each tool gets its own mechanism, because the two share nothing:

| | Claude Code | Codex |
|---|---|---|
| Mechanism | [hooks](https://code.claude.com/docs/en/hooks) | `notify` in `config.toml` |
| Events | SessionStart · UserPromptSubmit · Stop · Notification · SessionEnd | `agent-turn-complete` |
| Writes to | `~/.claude/settings.json` | `~/.codex/config.toml` |
| Coexistence | sits beside your own hooks | *chains* to whatever `notify` was already set |

Turn them on in **Settings → Live reporting**.

<img src="docs/images/settings.png" width="620" alt="Settings">

Both are opt-in and reversible: uninstalling restores `config.toml`
byte-for-byte and removes only Perch's own hook entries.

Reports land as small JSON files under
`~/Library/Application Support/Perch/Reports/`. The filesystem is the transport
on purpose — a hook is a short-lived process that must not block on a socket
handshake, the reports survive Perch being closed, and nothing is lost if Perch
starts late. Perch watches those directories, so a hook firing refreshes the
notch immediately rather than at the next poll.

---

## Where the numbers come from

| | Claude Code | Codex |
|---|---|---|
| Sessions | `~/.claude/projects/**/*.jsonl` | `~/.codex/sessions/**/rollout-*.jsonl` |
| Task state | hooks (push) → inference | `notify` (push) → lifecycle events |
| Tokens | per-request `usage`, deduplicated | `token_count`, already cumulative |
| Quota | [status line](https://code.claude.com/docs/en/statusline) | `account/rateLimits/read` over the app-server protocol |
| Context window | status line (`context_window_size`) | log (`model_context_window`) |

A handful of things this got wrong first, which the code now comments:

**Tokens are counted once.** Providers disagree about cached input: Codex
reports `input_tokens` with cached tokens *already inside it*
(`input + output == total`), while Anthropic reports cache reads and writes
*alongside* `input`. Perch normalises both so cache is always a breakdown of
input, never extra volume — getting this wrong inflated Codex by ~2×.

**A response is counted once, too.** Claude Code writes one `assistant` record
per content block, each repeating the whole response's usage. Deduplicating on
`(message.id, requestId)` cut a 1.84× overcount.

**Usage is read from the whole log, not its tail.** A 15 MB session log means a
256 KB tail sees ~1.7% of the requests. Totals come from a streaming full-file
pass, cached per file by byte offset so a two-second poll only parses newly
appended bytes.

**Hidden sessions still cost money.** Codex subagents get no row — one request
can spawn a dozen — but they were also being dropped from the totals, where on a
normal day they are the overwhelming majority of spend. Rows and accounting are
separate concerns now.

**Quota belongs to the account, not a session** — and outlives it. Providers
report it separately from sessions, so a tool that hasn't run recently still
shows its allowance.

**A reading that can't refresh itself is kept, not discarded.** Codex answers
live. Claude Code's arrives only while a session renders a status line, so once
that session ends nothing can refresh it. Discarding it made quota vanish
minutes later; it's kept and captioned with its age instead. Within a window
usage only grows, so an older percentage is a floor. What *does* make a reading
meaningless is its window passing `resets_at` — that's dropped regardless.

**"Needs approval" is attention, not completion.** Claude Code's `Notification`
hook also fires on `idle_prompt`, mid-turn. Subscribing to all of it made the
completion chime announce tasks that hadn't finished.

---

## Writing a plugin

A plugin is any executable that prints a JSON array of sessions on stdout. No
Swift required. Drop a directory into
`~/Library/Application Support/Perch/Plugins/<your-tool>/`:

```json
{
  "id": "my-agent",
  "displayName": "My Agent",
  "symbol": "sparkles",
  "accentHex": "#4285F4",
  "command": "probe",
  "timeout": 5,
  "availabilityPath": "~/.my-agent"
}
```

Your executable prints:

```json
[{
  "nativeID": "abc123",
  "title": "Fix the login bug",
  "state": "running",
  "workingDirectory": "/Users/me/proj",
  "usage": { "input": 1200, "output": 340, "contextWindow": 128000 },
  "target": "bundle:com.example.MyAgent"
}]
```

Only `nativeID`, `title` and `state` are required.

- **`state`** — `running`, `awaitingInput`, `awaitingApproval`, `completed`, `failed`
- **`target`** — `pid:1234`, `bundle:com.example.App`, `url:https://…`, `file:/path`

A working example is in [`examples/gemini-plugin/`](examples/gemini-plugin/).
Plugins run as you, on every poll, so keep them fast — Perch enforces the
timeout, and one that hangs, crashes or prints garbage is reported in the panel
footer without affecting the others.

Prefer Swift? Conform to `AgentProvider` from the `PerchKit` library.

## Design notes

- **Polling adapts.** Two seconds while something is running, ten when idle.
- **Logs are tailed for display, streamed for totals.** Different jobs, different reads.
- **The panel never steals focus.** A `.nonactivatingPanel` that can become key
  so clicks land, but never main.
- **Providers are isolated.** Polled concurrently; one throwing or hanging can't
  stall the others.
- **Colors are explicit, not semantic.** The panel is always dark, so
  `.secondary` would resolve against the wrong background.
- **Works without a notch.** Falls back to a centred strip in the menu bar.

## Tests

```bash
swift test
```

144 tests. The ones that matter most re-derive the numbers **straight from the
raw logs and the Codex protocol, independently of Perch's own parsers**, and
assert the Usage tab matches — for both tools and every quota bucket. That's
what stops displayed usage drifting from reality, rather than only checking
Perch against itself.

The rest cover state inference, the token and context distinctions, rate-limit
parsing, stats aggregation, completion-alert debouncing, settings persistence,
hover trigger bounds, panel geometry, plugin behaviour including timeout and
malformed output, and the rename migration.

## Prior art

The notch geometry and non-activating panel follow patterns established by
[DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) — deriving exact
bounds from `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` rather than
hardcoding sizes — and [TheBoringNotch](https://github.com/TheBoringTeam/theboringnotch).

The usage plumbing owes a lot to [ccusage](https://github.com/ccusage/ccusage)
(5-hour block reconstruction, the response dedup key) and
[Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor)
(provenance labels on every figure).

Those tools surface media, files and system HUDs, or live in a terminal. Perch
surfaces agent task state on the notch, and is built around a plugin boundary so
any tool can appear in it.

## License

MIT
