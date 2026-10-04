#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/codex-window-keeper"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
LAUNCHD_LABEL="com.matpb.codex-window-keeper"
CONFIG_FILE="$CONFIG_DIR/config"

# uname -s is the real detection; OSTYPE (a bash builtin, no external binary
# needed) is the fallback for a PATH stripped down to bare essentials.
if command -v uname >/dev/null 2>&1; then
  OS="$(uname -s)"
else
  case "${OSTYPE:-}" in
    darwin*) OS="Darwin" ;;
    *) OS="Linux" ;;
  esac
fi

no_enable=0
for arg in "$@"; do
  case "$arg" in
    --no-enable) no_enable=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# Resolves CODEX_BIN preferring an existing config's value over `command -v codex`.
resolve_codex_bin() {
  local from_config=""
  if [[ -f "$CONFIG_FILE" ]]; then
    from_config="$(grep -E '^CODEX_BIN=' "$CONFIG_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2-)"
  fi
  if [[ -n "$from_config" ]]; then
    printf '%s' "$from_config"
  else
    command -v codex 2>/dev/null || true
  fi
}

# Collects every missing dependency before failing, so one preflight run tells
# the user everything they need instead of one item at a time.
preflight_check() {
  local missing_names=() missing_hints=()

  if ! command -v jq >/dev/null 2>&1; then
    missing_names+=("jq")
    missing_hints+=("dnf install jq / apt install jq / brew install jq")
  fi
  if ! command -v mkfifo >/dev/null 2>&1; then
    missing_names+=("mkfifo")
    missing_hints+=("mkfifo ships with coreutils; something is very wrong if it is missing")
  fi
  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    missing_names+=("timeout or gtimeout")
    missing_hints+=("dnf install coreutils / apt install coreutils (Linux) / brew install coreutils, which provides gtimeout (macOS)")
  fi

  if [[ "$OS" == "Darwin" ]]; then
    if ! command -v launchctl >/dev/null 2>&1; then
      missing_names+=("launchctl")
      missing_hints+=("launchctl ships with macOS; something is very wrong if it is missing")
    fi
  elif ! command -v systemctl >/dev/null 2>&1; then
    missing_names+=("systemctl")
    missing_hints+=("install systemd (this tool requires a systemd user session)")
  else
    local sysout
    sysout="$(systemctl --user is-system-running 2>&1)" || true
    if [[ -z "$sysout" ]]; then
      missing_names+=("systemctl --user session")
      missing_hints+=("run 'systemctl --user status' to diagnose, and 'loginctl enable-linger \$USER' if needed")
    fi
  fi

  local codex_bin
  codex_bin="$(resolve_codex_bin)"
  if [[ -z "$codex_bin" ]]; then
    missing_names+=("codex")
    missing_hints+=("install the Codex CLI and sign in: https://github.com/openai/codex")
  elif ! "$codex_bin" --version >/dev/null 2>&1; then
    missing_names+=("codex (found at $codex_bin but --version failed)")
    missing_hints+=("check that $codex_bin is a working Codex CLI binary")
  fi

  if [[ ${#missing_names[@]} -gt 0 ]]; then
    echo "missing dependencies:" >&2
    local i
    for i in "${!missing_names[@]}"; do
      echo "  ${missing_names[$i]}: ${missing_hints[$i]}" >&2
    done
    exit 1
  fi
}

# Non-fatal: warns per configured account if it looks like codex was never logged in.
warn_missing_credentials() {
  local accounts="default"
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    accounts="${ACCOUNTS:-default}"
  fi

  local acc_arr label codex_home credpath var
  IFS=' ' read -ra acc_arr <<< "$accounts"
  for label in "${acc_arr[@]+"${acc_arr[@]}"}"; do
    if [[ "$label" == "default" ]]; then
      codex_home="${CODEX_HOME_default:-${CODEX_HOME:-$HOME/.codex}}"
    else
      var="CODEX_HOME_$label"
      codex_home="${!var:-}"
      [[ -z "$codex_home" ]] && continue
    fi
    credpath="$codex_home/auth.json"
    if [[ ! -f "$credpath" ]]; then
      echo "warning: account '$label' not logged in, run \`codex login\` (expected $credpath)"
    fi
  done
}

preflight_check
warn_missing_credentials

mkdir -p "$BIN_DIR"
install -m 755 "$SCRIPT_DIR/bin/codex-window-keeper" "$BIN_DIR/codex-window-keeper"
echo "installed $BIN_DIR/codex-window-keeper"

mkdir -p "$CONFIG_DIR"
if [[ ! -f "$CONFIG_FILE" ]]; then
  codex_bin="$(resolve_codex_bin)"
  sed "s#^CODEX_BIN=.*#CODEX_BIN=$codex_bin#" "$SCRIPT_DIR/config.example" > "$CONFIG_FILE"
  echo "wrote config: $CONFIG_FILE"
else
  echo "config already exists, leaving as is: $CONFIG_FILE"
fi

if [[ "$OS" == "Darwin" ]]; then
  mkdir -p "$LAUNCHD_DIR" "${XDG_STATE_HOME:-$HOME/.local/state}/codex-window-keeper"
  sed "s#__HOME__#$HOME#g" "$SCRIPT_DIR/launchd/$LAUNCHD_LABEL.plist" > "$LAUNCHD_DIR/$LAUNCHD_LABEL.plist"
  echo "installed launchd agent to $LAUNCHD_DIR/$LAUNCHD_LABEL.plist"

  if [[ "$no_enable" -eq 1 ]]; then
    echo "skipped enabling the agent (--no-enable). To enable it later, run:"
    echo "  launchctl bootstrap gui/\$(id -u) $LAUNCHD_DIR/$LAUNCHD_LABEL.plist"
  else
    launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$LAUNCHD_DIR/$LAUNCHD_LABEL.plist"
    echo "enabled and started $LAUNCHD_LABEL"
  fi
else
  mkdir -p "$SYSTEMD_USER_DIR"
  install -m 644 "$SCRIPT_DIR/systemd/codex-window-keeper.service" "$SYSTEMD_USER_DIR/codex-window-keeper.service"
  install -m 644 "$SCRIPT_DIR/systemd/codex-window-keeper.timer" "$SYSTEMD_USER_DIR/codex-window-keeper.timer"
  echo "installed systemd units to $SYSTEMD_USER_DIR"

  systemctl --user daemon-reload

  if [[ "$no_enable" -eq 1 ]]; then
    echo "skipped enabling the timer (--no-enable). To enable it later, run:"
    echo "  systemctl --user enable --now codex-window-keeper.timer"
  else
    systemctl --user enable codex-window-keeper.timer
    systemctl --user restart codex-window-keeper.timer
    echo "enabled and started codex-window-keeper.timer"
  fi
fi
