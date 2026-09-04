<div align="center">

<img src="docs/images/icon.png" width="112" alt="Perch">

# Perch

### Your coding agents, perched on the notch.

Claude Code and Codex, always in the corner of your eye —
who's working, who's waiting on you, and how much quota is left.

[繁體中文](docs/README.zh-TW.md) · macOS 14+ · MIT

<img src="docs/images/collapsed.png" width="440" alt="Perch sitting on the notch">

</div>

---

## Install

1. [**Download Perch 0.1.0**](https://github.com/ctudoudou/Perch/releases/latest) and unzip it.
2. Drag `Perch.app` into `/Applications`.
3. Run this once, **before** opening it:

```bash
xattr -cr /Applications/Perch.app
```

Then launch it like any other app.

Step 3 is not optional. Perch isn't notarized, so macOS marks every file inside
the bundle as quarantined and will tell you the app is damaged, offering only
*Move to Bin*. `xattr -cr` clears the whole bundle — clearing just the top level
leaves the binary flagged and the app still won't open.

macOS 14 or later. Universal, Apple silicon and Intel.

---

## Why

I kept losing track of my own agents.

You give Claude Code something long, switch to another window, and forget about
it. Meanwhile Codex is running somewhere else. Ten minutes later you're tabbing
around trying to work out which one is still thinking, which one has been
waiting on you the whole time, and whether you're about to hit a limit.

The notch is dead space that's already in your eyeline. Perch puts the answer
there.

## At rest

Two small clusters hug the notch and leave the cutout itself clear: a pulsing
dot and a count on the left, a badge per tool on the right — dimmed when idle,
with a small marker when something needs you.

That's all it does until you look at it. Point at the notch and the panel drops
down.

<img src="docs/images/tasks.png" width="640" alt="The Tasks panel">

Each session shows its state, project, branch, how full the context window is,
and the last few turns — enough to tell whether it's on track without switching
to it. Click a row to expand, or the arrow to jump straight to the app.

The hover target is the notch strip and those clusters, nothing more. Moving
your pointer across the middle of the screen doesn't set it off.

## Usage you can trust

<img src="docs/images/usage.png" width="640" alt="The Usage panel">

Spend per tool, and every quota bucket your account actually holds, with reset
countdowns. Codex hands out a general allowance *and* per-model ones, so each is
labelled — a model bucket sitting at 0% tells you nothing about the general one,
and conflating them is how you get caught out.

The numbers come from the tools themselves rather than being estimated. Where a
reading can't refresh itself, it says how old it is instead of pretending to be
current.

## Where the time went

<img src="docs/images/stats.png" width="640" alt="The Stats panel">

Sessions, messages, tokens, active days, streaks, peak hour, favourite model —
across all time, 30 days or 7. The **Models** view splits the same range by
model with stacked daily bars.

---

## Let the tools tell you

Reading log files only gets you so far: a file's timestamp can't tell the
difference between a model that's thinking and one that finished thirty seconds
ago. Both tools can simply *say* what happened — a lifecycle event fires at the
transition and names it.

<img src="docs/images/settings.png" width="640" alt="Settings">

Turn it on in **Settings → Live reporting**. Each tool gets its own mechanism,
because the two have nothing in common:

| | Claude Code | Codex |
|---|---|---|
| Mechanism | [hooks](https://code.claude.com/docs/en/hooks) | `notify` in `config.toml` |
| Writes to | `~/.claude/settings.json` | `~/.codex/config.toml` |
| If you already use it | Perch sits beside your own hooks | Perch *chains* to your existing program |

This edits your config, so it's opt-in and it's reversible. Turning it off
restores `config.toml` byte-for-byte and removes only Perch's own hook entries.
Nothing you had set up gets replaced.

---

## Keeping the numbers honest

Most of the work in Perch went here, because usage data is easy to display and
surprisingly easy to get wrong. A few of the traps, all of which I fell into
first:

**Providers disagree about cached tokens.** Codex counts cache *inside*
`input_tokens`; Anthropic reports it alongside. Add them the same way and Codex
inflates by roughly 2×.

**Claude Code writes one record per content block**, each repeating the whole
response's usage. Counting records instead of responses overcounted by 1.84×.

**A 15 MB session log doesn't fit in a tail read.** Totals stream the whole
file, cached by byte offset so a two-second poll only parses what's new.

**Hidden sessions still cost money.** Codex subagents don't get their own row —
one request can spawn a dozen — but on a normal day they're most of the spend,
so they still count.

**Quota belongs to the account, not a session.** It outlives whatever ran last,
and a tool that's been quiet all evening still has an allowance worth showing.

There are 144 tests, and the ones that matter re-derive these numbers straight
from the raw logs and the Codex protocol — independently of Perch's own parsers
— then assert the UI agrees. An earlier version of that check shared a bug with
the code it was checking and cheerfully confirmed a total nearly twice reality,
which is exactly why it works that way now.

## Adding your own tool

Perch ships with Claude Code and Codex. Anything else is a plugin, and a plugin
is just an executable that prints JSON:

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

Drop it with a small `plugin.json` into
`~/Library/Application Support/Perch/Plugins/`. Only `nativeID`, `title` and
`state` are required; `state` is one of `running`, `awaitingInput`,
`awaitingApproval`, `completed`, `failed`. There's a working example in
[`examples/gemini-plugin/`](examples/gemini-plugin/).

Plugins run on every poll, so keep them quick. Perch enforces a timeout, and one
that hangs or prints nonsense gets reported in the panel rather than taking
everything else down with it.

Prefer Swift? Conform to `AgentProvider` from `PerchKit`.

## Build from source

Skips the quarantine step entirely:

```bash
./build-app.sh release --universal
open build/Perch.app
```

Perch is an accessory app — no Dock icon, everything lives in the menu bar item
and the notch. To have it there every day, add it under
System Settings → General → Login Items.

## Thanks

The notch geometry follows [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit),
which works out exact bounds from `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`
instead of hardcoding sizes, and [TheBoringNotch](https://github.com/TheBoringTeam/theboringnotch)
for the hover-to-expand feel.

The usage side owes a lot to [ccusage](https://github.com/ccusage/ccusage) —
reading its source is where I found the response dedup key that fixed my 1.84×
overcount — and to [Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor)
for the idea of labelling every figure with where it came from.

## License

MIT
