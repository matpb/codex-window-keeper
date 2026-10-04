#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$SCRIPT_DIR/bin/codex-window-keeper"

TMP_ROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

export XDG_CONFIG_HOME="$TMP_ROOT/config"
export XDG_STATE_HOME="$TMP_ROOT/state"

CONFIG_DIR="$XDG_CONFIG_HOME/codex-window-keeper"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/config" <<'EOF'
CODEX_BIN=/nonexistent/codex
MODEL=gpt-5.6-luna
ACCOUNTS="default"
WINDOW_SECS=18000
PING_TIMEOUT=180
RPC_TIMEOUT=30
PROMPT="Reply with the single word: ok. Do not use any tools."
EOF

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Source, don't run: the BASH_SOURCE guard keeps main() from firing on source.
# shellcheck disable=SC1090
source "$CLI"
load_config
CODEX_HOME_default="$TMP_ROOT/account"
mkdir -p "$CODEX_HOME_default"
printf '{"auth_mode":"chatgpt","tokens":{"account_id":"test"}}\n' > "$CODEX_HOME_default/auth.json"

NOW="$(date +%s)"

# 1: window active -> skip
read_limits() { printf '{"primary":{"usedPercent":9,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":23,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus","limitName":null}\n' "$((NOW + 3600))" "$((NOW + 500000))"; }
OUT="$(decide_dry_run default 0)"
echo "$OUT" | grep -q "would-skip default" || fail "expected would-skip for active window, got: $OUT"

# 2: resetsAt in the past -> ping
read_limits() { printf '{"primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":23,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus","limitName":null}\n' "$((NOW - 3600))" "$((NOW + 500000))"; }
OUT="$(decide_dry_run default 0)"
echo "$OUT" | grep -q "would-ping default" || fail "expected would-ping for past resetsAt, got: $OUT"

# 3: missing window metadata must not cause a blind ping
read_limits() { printf '{"primary":{"usedPercent":0,"windowDurationMins":null,"resetsAt":null},"secondary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":null},"planType":"plus","limitName":null}\n'; }
OUT="$(decide_dry_run default 0)"
echo "$OUT" | grep -q "would-backoff default" || fail "expected would-backoff for missing window data, got: $OUT"

# 4: RPC read failure -> backoff
read_limits() { return 1; }
OUT="$(decide_dry_run default 0)"
echo "$OUT" | grep -q "would-backoff default" || fail "expected would-backoff on RPC failure, got: $OUT"

# 5: --force with an active window -> ping
read_limits() { printf '{"primary":{"usedPercent":9,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":23,"windowDurationMins":10080,"resetsAt":%s},"planType":"plus","limitName":null}\n' "$((NOW + 3600))" "$((NOW + 500000))"; }
OUT="$(decide_dry_run default 1)"
echo "$OUT" | grep -q "would-ping default" || fail "expected would-ping for --force with active window, got: $OUT"

# 6: neither timeout nor gtimeout on PATH -> require_deps fails, names both
ERR="$(TIMEOUT_BIN="" bash -c '
  set -euo pipefail
  source "'"$CLI"'"
  TIMEOUT_BIN=""
  require_deps read
' 2>&1 >/dev/null)" && fail "expected require_deps to exit non-zero with no timeout binary" || true
printf '%s' "$ERR" | grep -q "timeout or gtimeout" || fail "expected missing-dep message to mention timeout or gtimeout, got: $ERR"

echo "ALL TESTS PASSED"
