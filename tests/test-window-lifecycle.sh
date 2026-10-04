#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected [$2], got [$1]"; }
count() { wc -l < "$TEST_ROOT/$1" | tr -d ' '; }
limits() {
  jq -n --argjson used "$1" --argjson reset "$2" \
    '{limitId:"codex",planType:"plus",primary:{usedPercent:$used,windowDurationMins:300,resetsAt:$reset},secondary:{usedPercent:51,windowDurationMins:10080,resetsAt:2000500000},credits:{hasCredits:false,unlimited:false,balance:"0"},rateLimitReachedType:null}' > "$TEST_ROOT/limits"
}
tick() { (ping_account default 0); }
force_ping() { (ping_account default 1); }
read_limits() {
  echo read >> "$TEST_ROOT/reads"
  [[ ! -f "$TEST_ROOT/read-fails" ]] || return 1
  cat "$TEST_ROOT/limits"
}
date() {
  if [[ "$1" == '+%s' ]]; then printf '%s\n' "$TEST_NOW"; else command date "$@"; fi
}
setup() {
  export TEST_ROOT="$TMP_ROOT/$1" TZ=UTC
  mkdir -p "$TEST_ROOT/config/codex-window-keeper" "$TEST_ROOT/account"
  export XDG_CONFIG_HOME="$TEST_ROOT/config" XDG_STATE_HOME="$TEST_ROOT/state"
  printf '{"auth_mode":"chatgpt","tokens":{"account_id":"account-a"}}\n' > "$TEST_ROOT/account/auth.json"
  : > "$TEST_ROOT/reads"
  : > "$TEST_ROOT/pings"
  cat > "$TEST_ROOT/codex" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == exec ]] || exit 91
[[ "${CODEX_HOME:-}" == "$TEST_ROOT/account" ]] || exit 92
echo ping >> "$TEST_ROOT/pings"
if [[ -f "$TEST_ROOT/ping-fails" ]]; then
  echo '{"type":"turn.failed","error":{"message":"test rejection"}}'
  exit 1
fi
if [[ -f "$TEST_ROOT/post-limits" ]]; then cp "$TEST_ROOT/post-limits" "$TEST_ROOT/limits"; fi
if [[ -f "$TEST_ROOT/fail-post-read" ]]; then touch "$TEST_ROOT/read-fails"; fi
echo '{"type": "turn.completed", "usage": {"input_tokens": 10, "output_tokens": 1}}'
FAKE
  chmod +x "$TEST_ROOT/codex"
  cat > "$TEST_ROOT/config/codex-window-keeper/config" <<EOF
CODEX_BIN="$TEST_ROOT/codex"
CODEX_HOME_default="$TEST_ROOT/account"
MODEL=gpt-5.6-luna
ACCOUNTS=default
WINDOW_SECS=18000
PING_TIMEOUT=5
RPC_TIMEOUT=1
BACKOFF_SECS=1800
PROMPT=ok
EOF
  source "$SCRIPT_DIR/bin/codex-window-keeper"
  load_config
  # Replace only the external quota read; keep decisions, locks, persistence,
  # timeouts, command arguments and subprocess restarts real.
  read_limits() {
    echo read >> "$TEST_ROOT/reads"
    [[ ! -f "$TEST_ROOT/read-fails" ]] || return 1
    cat "$TEST_ROOT/limits"
  }
  TEST_NOW=2000000000
}

test_sliding() {
  limits 0 2000018000; tick
  assert_eq "$(count pings)" 0 'first snapshot must observe'
  TEST_NOW=2000000600; limits 0 2000018600; tick
  assert_eq "$(count pings)" 1 'sliding snapshot must open window'
  TEST_NOW=2000001200; limits 0 2000019200; tick
  assert_eq "$(count pings)" 1 'unconfirmed success must not repeat'
}
test_fixed_zero() {
  limits 0 2000018000; tick
  TEST_NOW=2000000600; tick
  assert_eq "$(count pings)" 0 'zero percent with fixed anchor is active'
  [[ "$(run_status default)" == *ACTIVE* ]] || fail 'fixed anchor status'
  assert_eq "$(jq -r '.last_ping_at // 0' "$STATE_ROOT/default/state.json")" 0 'skip must not invent ping time'
}
test_rpc_backoff() {
  touch "$TEST_ROOT/read-fails"; tick
  TEST_NOW=2000000600; tick
  assert_eq "$(count reads)" 1 'backoff must suppress RPC until deadline'
  TEST_NOW=2000001800; tick
  assert_eq "$(count reads)" 2 'RPC retries at deadline'
}
test_ping_backoff() {
  touch "$TEST_ROOT/ping-fails"; limits 0 1999999990; tick
  TEST_NOW=2000000600; tick
  assert_eq "$(count pings)" 1 'failed request must back off across restarts'
  TEST_NOW=2000001800; tick
  assert_eq "$(count pings)" 2 'request retries at deadline'
}
test_success_cap() {
  limits 0 2000018000; tick
  for offset in 600 1200 1800 18000; do
    TEST_NOW=$((2000000000 + offset)); limits 0 "$((TEST_NOW + 18000))"; tick
  done
  assert_eq "$(count pings)" 1 'unconfirmed success cap survives restarts and gaps'
  TEST_NOW=2000018600; limits 0 2000036600; tick
  assert_eq "$(count pings)" 2 'unconfirmed success may retry after five hours'
}
test_confirmed_early_expiry() {
  limits 0 2000001200; force_ping
  assert_eq "$(count pings)" 1 'explicit ping completes'
  TEST_NOW=2000000600; tick
  TEST_NOW=2000001201; tick
  assert_eq "$(count pings)" 2 'actual confirmed expiry overrides five-hour fallback'
}
test_window_switch() {
  limits 10 2000000300; tick
  TEST_NOW=2000000600; limits 0 2000018600; tick
  assert_eq "$(count pings)" 0 'old window cannot prove new window slides'
  TEST_NOW=2000001200; limits 0 2000019200; tick
  assert_eq "$(count pings)" 1 'new sliding window is detected on next tick'
}
test_invalid_and_exhausted() {
  local snapshot
  for snapshot in \
    '{"primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":2000500000}}' \
    '{"primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":null}}' \
    '{"primary":{"usedPercent":"0","windowDurationMins":300,"resetsAt":2000018000}}' \
    '{"primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":2000018000}}' \
    '{"primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1999999900},"secondary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":2000500000}}'; do
    printf '%s\n' "$snapshot" > "$TEST_ROOT/limits"
    force_ping
  done
  assert_eq "$(count pings)" 0 'invalid or exhausted data must not spend even with force'
}
test_history_invalidation() {
  limits 0 2000018000; tick
  printf '{"auth_mode":"chatgpt","tokens":{"account_id":"account-b"}}\n' > "$TEST_ROOT/account/auth.json"
  TEST_NOW=2000000600; limits 0 2000018600; tick
  assert_eq "$(count pings)" 0 'account change discards history'
  TEST_NOW=2000003600; limits 0 2000021600; tick
  assert_eq "$(count pings)" 0 'long gap discards comparison'
  TEST_NOW=2000003000; limits 0 2000021000; tick
  assert_eq "$(count pings)" 0 'clock rollback discards comparison'
}
test_legacy_and_readonly() {
  mkdir -p "$STATE_ROOT/default"
  echo '{"resets_at":2000018000,"last_ping_at":2000000000,"last_result":"skip"}' > "$STATE_ROOT/default/state.json"
  limits 0 2000018000
  local before after
  before="$(cat "$STATE_ROOT/default/state.json")"
  [[ "$(decide_dry_run default 0)" == would-observe* ]] || fail 'legacy state cannot prove active window'
  [[ "$(run_status default)" == *OBSERVING* ]] || fail 'unknown zero must not show ACTIVE'
  after="$(cat "$STATE_ROOT/default/state.json")"
  assert_eq "$after" "$before" 'read-only commands must not write state'
  assert_eq "$(count pings)" 0 'read-only commands must not spend'
  tick
  assert_eq "$(jq -r '.last_ping_at // 0' "$STATE_ROOT/default/state.json")" 0 'legacy last_ping must be discarded'
}
test_stale_and_date() {
  limits 10 2000003600; tick
  touch "$TEST_ROOT/read-fails"
  [[ "$(run_status default)" == *UNKNOWN*source=stale* ]] || fail 'failed live read must not show cached ACTIVE'
  assert_eq "$(fmt_epoch 0)" '1970-01-01 00:00:00' 'date must support active PATH implementation'
}
test_lock() {
  mkdir -p "$STATE_ROOT/default/lock.d"
  printf '%s\n' "$$" > "$STATE_ROOT/default/lock.d/pid"
  limits 0 1999999990; tick
  assert_eq "$(count pings)" 0 'live lock holder prevents another request'
  assert_eq "$(count reads)" 0 'live lock holder prevents overlapping read'
}
test_clock_after_success() {
  limits 0 2000018000; tick
  TEST_NOW=2000000600; limits 0 2000018600; tick
  TEST_NOW=1999999000; limits 0 2000017000; tick
  TEST_NOW=1999999600; limits 0 2000017600; tick
  assert_eq "$(count pings)" 1 'clock rollback must not erase successful-request protection'
}
test_cached_then_sliding() {
  limits 0 2000018000; tick
  TEST_NOW=2000000600; tick
  TEST_NOW=2000001200; limits 0 2000019200; tick
  assert_eq "$(count pings)" 0 'cache refresh jump alone must not trigger request'
  TEST_NOW=2000001800; limits 0 2000019800; tick
  assert_eq "$(count pings)" 1 'cache must not permanently hide sliding window'
}
test_secondary_and_corrupt_state() {
  limits 1 2000003600
  jq '.primary as $p | .primary=.secondary | .secondary=$p' "$TEST_ROOT/limits" > "$TEST_ROOT/swapped"
  mv "$TEST_ROOT/swapped" "$TEST_ROOT/limits"
  tick
  [[ "$(run_status default)" == *ACTIVE* ]] || fail 'five-hour window must be selected by duration'
  echo 'broken-json' > "$STATE_ROOT/default/state.json"
  TEST_NOW=2000000600; limits 0 2000018600; tick
  assert_eq "$(count pings)" 0 'corrupt state must begin with observation'
}
test_ping_dry_run() {
  limits 0 1999999900
  (main ping --dry-run) > "$TEST_ROOT/dry-output"
  assert_eq "$(count pings)" 0 'ping --dry-run must not send a request'
  [[ ! -f "$STATE_ROOT/default/state.json" ]] || fail 'ping --dry-run wrote state'
}
test_bucket_change() {
  limits 10 2000018000; tick
  TEST_NOW=2000000600; limits 0 2000018000
  jq '.limitId="other"' "$TEST_ROOT/limits" > "$TEST_ROOT/changed"
  mv "$TEST_ROOT/changed" "$TEST_ROOT/limits"
  [[ "$(decide_dry_run default 0)" == would-observe* ]] || fail 'confirmed reset must not cross quota buckets'
}
test_clock_backoff_deadline() {
  touch "$TEST_ROOT/read-fails"; tick
  TEST_NOW=1999913600; tick
  TEST_NOW=1999915405; tick
  assert_eq "$(count reads)" 2 'rebased retry deadline must not move on every tick'
}
test_force_post_read_failure() {
  limits 10 2000000300
  touch "$TEST_ROOT/fail-post-read"
  force_ping
  rm "$TEST_ROOT/read-fails" "$TEST_ROOT/fail-post-read"
  TEST_NOW=2000000600; tick
  assert_eq "$(count pings)" 2 'failed post-read must not discard a known earlier expiry'
}
test_force_post_read_invalid() {
  limits 10 2000000300
  echo '{}' > "$TEST_ROOT/post-limits"
  force_ping
  rm "$TEST_ROOT/post-limits"
  TEST_NOW=2000000600; limits 10 2000000300; tick
  assert_eq "$(count pings)" 2 'invalid post-read must not discard a known earlier expiry'
}
test_unconfirmed_bucket_change() {
  limits 0 2000018000; tick
  TEST_NOW=2000000600; limits 0 2000018600; tick
  for offset in 1200 1800; do
    TEST_NOW=$((2000000000 + offset)); limits 0 "$((TEST_NOW + 18000))"
    jq '.limitId="other"' "$TEST_ROOT/limits" > "$TEST_ROOT/changed"
    mv "$TEST_ROOT/changed" "$TEST_ROOT/limits"
    tick
  done
  assert_eq "$(count pings)" 2 'success protection must not suppress a different quota bucket'
}

failed=0
for case_name in sliding fixed_zero rpc_backoff ping_backoff success_cap confirmed_early_expiry window_switch invalid_and_exhausted history_invalidation legacy_and_readonly stale_and_date lock clock_after_success cached_then_sliding secondary_and_corrupt_state ping_dry_run bucket_change clock_backoff_deadline force_post_read_failure force_post_read_invalid unconfirmed_bucket_change; do
  # Deliberately not an if/|| function invocation: preserve errexit in each case.
  set +e
  (set -e; setup "$case_name"; "test_$case_name")
  case_rc=$?
  set -e
  if [[ "$case_rc" -eq 0 ]]; then echo "PASS $case_name"; else failed=$((failed + 1)); fi
done
[[ "$failed" -eq 0 ]] || fail "$failed lifecycle cases failed"
echo 'ALL LIFECYCLE TESTS PASSED'
