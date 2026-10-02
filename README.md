# AI Usage Monitor 📊

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6-orange?logo=swift&logoColor=white)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)](Sources/main.swift)

A tiny macOS menu bar app that keeps your Claude Code and Codex limits in sight. It runs
`claude -p /usage` and reads Codex's authenticated local app-server usage snapshot for you.

<p align="center">
  <img src="docs/menubar.png" width="360"
        alt="AI Usage Monitor in the macOS menu bar: a gauge icon followed by the session and weekly usage percentages">
</p>

The number sits in the system's own label colour, so it reads like every other menu bar
item in both light and dark mode. It turns red only past 85% — the one moment the number
is actually news.

## Why

`/usage` already tells you everything, but only from inside a session, and only if you stop
what you are doing to ask. This is that same report on a permanent shelf: the number lives
in the menu bar and the full breakdown is one click away.

It is the macOS counterpart of the Claude usage module in Omarchy's waybar.

## Usage

**Click** the gauge and switch between the **Claude** and **Codex** tabs for either report:

```
Claude Code · subscription
──────────────────────────────────────
Session                             43%
████████████████░░░░░░░░░░░░░░░░░░░░
███████████████████████████░░░░░░░░░
1h 12m left · resets Aug 28 at 8:59pm 76%

Week (all models)                    5%
██░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
██████████░░░░░░░░░░░░░░░░░░░░░░░░░░
4d 23h left · resets Sep 4 at 3:59pm 29%
──────────────────────────────────────
Model token share · last 7 days
claude-opus-4-1                     62%
████████████████████████░░░░░░░░░░░░
claude-sonnet-4-5                   38%
███████████████░░░░░░░░░░░░░░░░░░░░░
──────────────────────────────────────
Last 7d · 2829 requests · 21 sessions
  80% of your usage was at >150k context
  49% of your usage came from sessions active for 8+ hours
  14% of your usage came from subagent-heavy sessions
──────────────────────────────────────
Refresh Now (updated 17:15)          ⌘R
Menu Bar Shows                        ▸
Refresh Every                         ▸
Settings…                            ⌘,
Copy Report                          ⌘C
Launch at Login
──────────────────────────────────────
Quit AI Usage Monitor                ⌘Q
```

- **Settings…** — enable or disable monitoring per provider (Claude Code and Codex). A
  disabled provider stops being polled and disappears from the menu bar, tab and report.
- **Menu Bar Shows** — session percentage (default), week, both, or icon only.
- **Refresh Every** — 1, 5 (default), 15, 30 or 60 minutes. It also refreshes whenever you
  open the menu and whenever the Mac wakes from sleep.
- **Copy Report** — the raw `/usage` text on the clipboard.

Each limit gets two capsule bars drawn like the model bars: usage on top, in the system
accent colour (red past 85%), and beneath it a grey clock bar with the share of that limit's
window (5 hours or 7 days) that has already gone by, captioned with the time left until it resets.
Read the pair together: a usage bar longer than its clock bar means you are spending faster
than the window is passing; a shorter one means you have room to spare.

Every limit row the CLI reports is rendered, so a plan that reports a separate Opus weekly
cap gets its own gauge without any change here.

The model bars show each model's share of recorded token usage over the last seven days.
They are calculated separately for Claude and Codex from local session records, so they
describe token mix rather than subscription quota. The app reads timestamps, model identifiers,
and token counts from Claude Code's local records and Codex's session files; it doesn't retain
prompt, response, or tool content. If Claude transcripts are unavailable, it falls back to
Claude Code's daily model totals in `stats-cache.json`.

Two headless entry points, for scripts:

```sh
/Applications/AIUsageMonitor.app/Contents/MacOS/AIUsageMonitor --print            # limits and window elapsed to stdout
/Applications/AIUsageMonitor.app/Contents/MacOS/AIUsageMonitor --print-codex      # Codex limits
/Applications/AIUsageMonitor.app/Contents/MacOS/AIUsageMonitor --login-item on    # or off / status
```

If macOS reports `requires approval`, enable it under
**System Settings → General → Login Items**.

## Install

```sh
git clone https://github.com/marionuevo/ClaudeUsage.git
cd ClaudeUsage
./build.sh
cp -R build/AIUsageMonitor.app /Applications/
codesign --force --sign - /Applications/AIUsageMonitor.app
open /Applications/AIUsageMonitor.app
```

Re-signing after the copy matters — a moved bundle's ad-hoc signature can otherwise go
stale and macOS will refuse to launch it.

Requires the Claude Code and/or Codex CLI on the machine, signed in. If one is unavailable,
its tab shows the error while the other continues to work normally.

## Build

```sh
./build.sh          # produces build/AIUsageMonitor.app (universal arm64 + x86_64, ad-hoc signed)
```

Requires only the Xcode Command Line Tools (`xcode-select --install`) — there is no Xcode
project and no package manager. The entire app is one Swift file, `Sources/main.swift`,
compiled straight into a hand-assembled `.app` bundle by `build.sh`.

Minimum macOS is 13. The gauge glyph is a macOS 14 SF Symbol, so on 13 the icon falls back
to the plain `gauge`.

## How it works

`/usage` is a *local* slash command: `claude -p "/usage"` answers in about a second, reads
your subscription limits over the same authenticated connection the CLI already uses, and
spends no tokens — the poll does not show up in the numbers it is reporting. The app runs
that command, parses the `Current …: N% used · resets …` lines with one regular expression,
and draws them.

The clock bars need each reset as an instant and the length of its window. Claude only
quotes the reset as text (`Oct 2 at 3:30pm (Atlantic/Canary)`), so the app reads it in the
quoted timezone and, when the year is missing, picks the year that puts the reset nearest to
now. The window comes from the row's label: a session is 5 hours, a week 7 days. Codex
reports both directly (`resetsAt` and `windowDurationMins`). A row whose reset can't be read
keeps its usage bar and simply goes without a clock bar.

Nothing else happens in the background: between refreshes the app is an idle timer and a
status item. It never reads your credentials — each CLI holds those — and it talks to no
network service of its own. For model shares, it scans recent local Claude transcripts and
Codex rollouts, using model names, timestamps, and token counts. It honors `CLAUDE_CONFIG_DIR`
and `CODEX_HOME` when set. Codex limit usage comes from `account/rateLimits/read` on a
short-lived local `codex app-server` process, including its rolling and weekly windows and
reset times.

The `claude` binary is found at `~/.local/bin`, `~/.claude/local`, Homebrew or `/usr/local`,
falling back to asking a login shell. A refresh that hangs is killed after 45 seconds, and
any failure — CLI missing, signed out, timed out — shows as `!` in the menu bar with the
reason in the menu.

## License

[MIT](LICENSE) © 2026 Mario Nuevo
