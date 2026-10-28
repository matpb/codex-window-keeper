#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

export XDG_CONFIG_HOME="$TMP_ROOT/config"
export XDG_STATE_HOME="$TMP_ROOT/state"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/bin/codex-window-keeper"

WINDOW_SECS=18000
BACKOFF_SECS=1800
PING_TIMEOUT=180
RPC_TIMEOUT=30
MODEL=gpt-5.6-luna
REASONING_EFFORT=low
PROMPT=ok
ACCOUNTS=default
NOW=1700000000
CLOCK_FILE="$TMP_ROOT/clock"
printf '%s\n' "$NOW" > "$CLOCK_FILE"

# Freeze the clock, including across the command substitutions used for RPC reads.
date() {
  if [[ "${1:-}" == "+%s" ]]; then
    cat "$CLOCK_FILE"
  else
    command date "$@"
  fi
}

fail() { echo "FAIL: $1"; exit 1; }

set_limits() {
  MOCK_LIMITS="$(jq -nc --argjson used "$1" --argjson reset "$((NOW + $2))" \
    --argjson duration "$3" \
    '{primary:{usedPercent:$used,resetsAt:$reset,windowDurationMins:$duration},
      secondary:{usedPercent:23,resetsAt:1700500000,windowDurationMins:10080},planType:"plus"}')"
  printf '%s\n' "$NOW" > "$CLOCK_FILE"
  READ_LATENCY=0
}

read_limits() {
  printf '%s\n' "$((NOW + READ_LATENCY))" > "$CLOCK_FILE"
  printf '%s\n' "$MOCK_LIMITS"
}

expect_decision() {
  local out
  out="$(decide_dry_run default 0)"
  [[ "$out" == "would-$1 default"* ]] || fail "$2: $out"
}

# An unused window reports now + its full duration, not a null/past reset.
set_limits 0 18000 300
expect_decision ping "idle window must not be mistaken for an active window"
out="$(run_status "")"
[[ "$out" == *LAPSED* ]] || fail "status must show the idle window as LAPSED: $out"
[[ "$out" == *resets=-* ]] || fail "status must not display a placeholder reset as a real reset: $out"

# A reset synthesized while the RPC is in flight can be later than read-start + duration.
set_limits 0 18002 300
expect_decision ping "idle reset generated during the read"

# Compare against the start of the read, not a later timestamp after RPC latency.
set_limits 0 18000 300
READ_LATENCY=2
expect_decision ping "idle reset returned after RPC latency"

set_limits 0 1 300
READ_LATENCY=2
expect_decision ping "window that expires during the RPC read"

# A real low-cost ping can stay below the displayed 1% resolution.
set_limits 0 17940 300
expect_decision skip "active window with usage rounded down to zero"
out="$(run_status "")"
[[ "$out" == *ACTIVE* ]] || fail "zero-percent active window must remain ACTIVE: $out"

set_limits 0 17999 300
expect_decision skip "zero-percent window that started one second before the read"

set_limits 1 18000 300
expect_decision skip "nonzero usage is evidence of an active window"
set_limits 0 3600 null
expect_decision skip "missing duration preserves the existing future-reset behavior"
set_limits null 18000 300
expect_decision skip "unknown usage must not be treated as zero"

# Exercise the real tick and state writes with a fake Codex executable: no auth or API calls.
export TEST_PING_LOG="$TMP_ROOT/pings"
CODEX_BIN="$TMP_ROOT/codex"
cat > "$CODEX_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == exec ]] || exit 1
printf 'ping\n' >> "$TEST_PING_LOG"
printf '{"type":"turn.completed"}\n'
EOF
chmod +x "$CODEX_BIN"
without_timeout() { shift; "$@"; }
TIMEOUT_BIN=without_timeout

set_limits 0 18000 300
IDLE_LIMITS="$MOCK_LIMITS"
set_limits 0 17995 300
ACTIVE_LIMITS="$MOCK_LIMITS"
read_limits() {
  if [[ -s "$TEST_PING_LOG" ]]; then
    printf '%s\n' "$ACTIVE_LIMITS"
  else
    printf '%s\n' "$IDLE_LIMITS"
  fi
}

# A subshell keeps ping_account's EXIT trap from replacing this test's cleanup trap.
(run_tick 0 0 "")
[[ "$(wc -l < "$TEST_PING_LOG" | tr -d ' ')" -eq 1 ]] || fail "idle tick must send one ping"
state="$STATE_ROOT/default/state.json"
jq -e '.last_result == "ok" and .source == "rpc" and .used_pct == 0' "$state" >/dev/null \
  || fail "the successful ping must retain the real zero-percent active window"
[[ ! -d "$STATE_ROOT/default/lock.d" ]] || fail "tick must release its lock"

printf '%s\n' "$((NOW + 600))" > "$CLOCK_FILE"
(run_tick 0 0 "")
[[ "$(wc -l < "$TEST_PING_LOG" | tr -d ' ')" -eq 1 ]] || fail "next tick must not ping the zero-percent active window again"
jq -e '.last_result == "skip"' "$state" >/dev/null || fail "active tick must skip"

read_limits() { return 1; }
out="$(run_status "")"
[[ "$out" == *ACTIVE* && "$out" == *source=stale* ]] || fail "stale state fallback must still work: $out"

# A successful exec alone must not make a moving placeholder a confirmed RPC window.
printf '%s\n' "$NOW" > "$CLOCK_FILE"
read_limits() { printf '%s\n' "$IDLE_LIMITS"; }
(run_tick 1 0 "")
jq -e '.source == "assumed" and .last_result == "ping-ok-read-failed"' "$state" >/dev/null \
  || fail "post-ping idle placeholder must not be saved as a confirmed active window"

echo "ALL IDLE WINDOW TESTS PASSED"
