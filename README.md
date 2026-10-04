# codex-window-keeper

Keeps a Codex CLI 5-hour usage window always open.

![license](https://img.shields.io/badge/license-MIT-blue.svg) ![platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS-lightgrey.svg) ![shell](https://img.shields.io/badge/shell-bash-4EAA25.svg?logo=gnu-bash&logoColor=white)

Never start a Codex 5-hour usage window cold again.

The ChatGPT plan used through the Codex CLI meters usage in a rolling 5-hour "primary"
window. The window is not anchored to the wall clock, it is anchored to your first
request. So when you sit down to work after a break, the clock starts with you, and if
you burn through the budget in three hours you wait two.

Every 10 minutes a timer checks the five-hour window. When it has expired, or successive
zero-use snapshots show the reset sliding with query time, the keeper sends a small
Codex request. A future reset time alone does not prove a window is open. Observing a
new zero-use window can take two ticks (up to about 20 minutes after expiry while the
machine is awake and reads succeed).

```
Without:   you start 9:00 ... budget gone 12:00 ... wait ... new window 14:00
With:      keeper opened 6:50 ... you start 9:00 ... reset 11:50, fresh budget, no wait
```

## How it's simpler than the Claude version

The same idea for Claude Code lives in
[claude-window-keeper](https://github.com/matpb/claude-window-keeper). The Codex
implementation is considerably smaller, for two reasons.

Codex's `codex exec` spends from the same ChatGPT plan quota as the interactive CLI when
signed in with `auth_mode: chatgpt`. There is no separate API credit pool to
avoid, so there is no need for a fake interactive session, a tmux window, hooks, or a
transcript to clean up afterward. Two things make this possible:

1. **Reading the current rate limits is free.** Codex's `app-server` exposes a JSON-RPC
   method, `account/rateLimits/read`, that returns the primary and secondary (weekly)
   window state without spending a single token. The keeper calls this on every tick and
   every `status` to decide, for free, whether a window is even open.
2. **The cheapest possible ping opens one.** When no window is active, the keeper runs
   `codex exec --ephemeral` with a throwaway one-word prompt on `gpt-5.6-luna` at low
   reasoning effort — of three models measured (`gpt-5.6-luna`, `gpt-5.5`,
   `gpt-5.6-terra`), it was the cheapest and the only one that emitted zero reasoning
   tokens at low effort. See [Cost](#cost) for the numbers. `--ephemeral` means it
   persists no session files, so there is nothing to clean up afterward.

## Who this is for

- You use the Codex CLI with a ChatGPT Plus/Pro/Team plan (`auth_mode: chatgpt` in
  `~/.codex/auth.json`).
- You work in bursts and keep running into the 5-hour limit.
- You want it to just run in the background and never think about it.

Not for API-key accounts (they have no 5-hour ChatGPT-plan window) and not for Windows.

## Quick start

```
cd codex-window-keeper
./install.sh
codex-window-keeper status
```

The installer checks that `jq`, `mkfifo`, `timeout` (or `gtimeout`), a working `codex`,
and a systemd user session (Linux) or `launchctl` (macOS) are present, and tells you exactly
what is missing if not. It then copies the script to `~/.local/bin`, writes a config
file, and starts a timer that ticks every 10 minutes: a systemd user timer on Linux, a
launchd agent on macOS.

`status` prints one line per account, from a live (free) rate-limit read:

```
default    ACTIVE   resets=2026-01-01 12:00:00 (in 2h15m) used_pct=15 weekly_pct=40 plan=plus source=live last_ping=2026-01-01 09:45:00 last_result=ok
```

On first run, before any ping, it shows live numbers as long as the RPC read works.
A zero-use window can show `OBSERVING` until successive snapshots distinguish a fixed
reset from a sliding one. `UNCONFIRMED` means a request completed but the window is not
yet confirmed; `EXHAUSTED` means a returned quota prevents an automatic ping.

## Requirements

- Linux with a systemd user session, or macOS.
- Codex CLI installed and signed in with a ChatGPT plan (`codex login`,
  `jq -r .auth_mode ~/.codex/auth.json` should print `chatgpt`).
- `jq`, `mkfifo` (ships with macOS), and `timeout` or `gtimeout` (`brew install
  coreutils` on macOS).
- Linux only: if you want it to keep working while you are logged out, run
  `loginctl enable-linger $USER`.

## Commands

```
codex-window-keeper status          # per account: window active or lapsed, live reset time
codex-window-keeper log             # last 50 log lines
codex-window-keeper tick            # what the timer runs: ping only if no window is active
codex-window-keeper tick --dry-run  # print what tick would do, touch nothing
codex-window-keeper ping            # force a ping now (add --account <label> for one account)
```

## Config

`~/.config/codex-window-keeper/config`, a plain shell file written by the installer:

```
CODEX_BIN=/path/to/codex          # resolved by install.sh; systemd/launchd's PATH is minimal
MODEL=gpt-5.6-luna
REASONING_EFFORT=low
ACCOUNTS="default"
WINDOW_SECS=18000
PING_TIMEOUT=180
RPC_TIMEOUT=30
BACKOFF_SECS=1800
PROMPT="Reply with the single word: ok. Do not use any tools."
```

Available model slugs depend on your plan and change over time. If `gpt-5.6-luna` isn't
offered on your account, set `MODEL` to whatever cheap/fast model your account does offer
— open the Codex TUI and use its `/model` picker to see the list.

Two Codex accounts on one machine? Each one lives in its own `CODEX_HOME`. Add a label per
account:

```
ACCOUNTS="default work"
CODEX_HOME_work=$HOME/.codex-work
```

`default` is your normal account (whatever `CODEX_HOME` is in your environment, usually
unset, meaning Codex uses `~/.codex`). Every other label needs a matching
`CODEX_HOME_<label>`.

To keep manual commands and the scheduler on the same account, set
`CODEX_HOME_default=$HOME/.codex` in the keeper config. State is bound to the resolved
directory and the account identity in `auth.json`. File-backed credentials are required;
keychain-only accounts without this file report `UNKNOWN` and do not automatically ping.

`RPC_TIMEOUT` bounds how long the free rate-limit read waits for a reply before giving up.
`BACKOFF_SECS` is how long the keeper waits before retrying after a failed read or a
failed ping, instead of assuming a fresh window it never actually earned.

## How it works

Every tick selects the window with `windowDurationMins=300`, regardless of its position
in the response. Nonzero usage with a future reset is active. For zero usage, snapshots
5–20 minutes apart distinguish a fixed reset from one that keeps moving to query time
plus five hours (60 seconds of tolerance). An ambiguous first snapshot is `OBSERVING`.

When a window expires or a sliding zero-use reset is detected, the keeper runs
`codex exec --ephemeral`, then re-reads limits. A completed request is `UNCONFIRMED`
until usage or a later fixed countdown confirms the window. Until confirmed, successful
automatic requests are limited to one every `WINDOW_SECS` (normally five hours). Once
confirmed, the real reset time takes precedence, including an earlier expiry.

Failed reads and requests suppress automatic retries for `BACKOFF_SECS`. Explicit
`ping`/`--force` bypass observation and retry delays, but still require valid window
data and skip known exhausted quotas. `ping --dry-run` never sends a request.

State version 2 separates last check, last attempt, last successful request, server
reset, and retry deadline. Old state is discarded because the previous `last_ping`
also recorded skips. Changing accounts invalidates state. A clock rollback invalidates
observations while preserving conservative request protection. `status` and dry-run
are read-only; failed live reads display `UNKNOWN source=stale`, not cached `ACTIVE`.

The Chinese design and verification record is in [docs/窗口保活修复方案.md](docs/窗口保活修复方案.md).

Run the offline tests (no model calls):

```sh
bash tests/test-decide.sh
bash tests/test-window-lifecycle.sh
```

### The FIFO/stdin constraint

`codex app-server` speaks JSON-RPC over stdin/stdout and answers asynchronously — a plain
`printf ... | codex app-server` gets the `initialize` reply, then the process exits at EOF
before `account/rateLimits/read`'s response is ever written, which looks exactly like the
method being unsupported. stdin has to stay open until the reply lands. This tool holds a
FIFO open (`read_limits` in `bin/codex-window-keeper`) and polls the output file for the
response, closing as soon as it lands. The server's stdout also carries unsolicited
notifications, so the response has to be picked out by its JSON-RPC `id`, not just "the
next line". The three messages actually sent:

```
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{...}}}
{"jsonrpc":"2.0","method":"initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":true}}
```

## Cost

| Model | Input | Output | Reasoning |
|---|---|---|---|
| gpt-5.6-luna | 18,558 | 5 | 0 |
| gpt-5.5 | 19,168 | 21 | 14 |
| gpt-5.6-terra | 21,300 | 25 | 18 |

Each ping on `gpt-5.6-luna` spends roughly **~18.5k input, 5 output** tokens of the
plan's budget — one Codex turn with no tools, at most about five a day, and usually
fewer since your own usage covers the hours you work. A full forced ping moved the
5-hour bucket by 0 percentage points and the weekly bucket by 0 percentage points, both
below the 1% resolution the API reports — in practice the keeper's cost is below the
metering floor at that ping rate. It's not free: it counts toward your 5-hour and
weekly limits like any other message, it's just too small to register at the reported
resolution.

## Where things live

- Config: `~/.config/codex-window-keeper/config`
- State root: `~/.local/state/codex-window-keeper/`
- Log: `~/.local/state/codex-window-keeper/keeper.log`
- Per account: `~/.local/state/codex-window-keeper/<label>/state.json` and `.../lock.d`
- Binary: `~/.local/bin/codex-window-keeper`

## Troubleshooting

- `status` shows `UNKNOWN source=stale`: the live RPC read failed (Codex not signed in,
  or `codex app-server` errored). Saved request history is shown without claiming an
  active live window.
- Timer not firing (Linux): `systemctl --user list-timers codex-window-keeper.timer`. If
  the user session is gone after logout, enable lingering (see Requirements).
- Timer not firing (macOS): `launchctl print gui/$(id -u)/com.matpb.codex-window-keeper`,
  and check `~/.local/state/codex-window-keeper/launchd.log`.
- `last_result=error` or `rpc-error`: check `codex-window-keeper log`, then try
  `codex-window-keeper ping` by hand. The usual cause is an expired sign-in — run
  `codex login`.
- Changed the config? Nothing to restart, every tick reads it fresh.

## Uninstall

```
./uninstall.sh           # removes the script and the scheduler unit, keeps config and state
./uninstall.sh --purge   # removes everything
```

Removes the systemd units on Linux, the launchd agent on macOS.

## Why not the interactive TUI, tmux, or a Stop hook

Unlike the Claude version, `codex exec` bills the same plan quota as the interactive CLI,
so there is no need to fake an interactive session in a tmux pane to avoid a separate
credit pool. `--ephemeral` also means there is no transcript to read back or clean up: the
rate limits come from the free `account/rateLimits/read` RPC instead of a status-line
hook.

## License

MIT.
