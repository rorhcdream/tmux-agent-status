#!/usr/bin/env bash
# tmux plugin entry point. tmux/TPM runs this on config load.
# It launches the status poller as a single background daemon tied to this
# tmux server, and (optionally) ensures the window-status-format shows the icon.

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLLER="$CURRENT_DIR/scripts/poller.sh"

# Called by the after-select-window hook (below): stamp the just-viewed window
# with the current time in ms, so the poller knows a completion has been seen.
# Instant on every visit — no dependence on catching #{window_active} at a tick.
if [ "${1:-}" = "mark-seen" ]; then
  # Ceil to end-of-second (+999): macOS `date` has no ms, but statusUpdatedAt
  # does — a floored stamp would be < a completion ts in the same second, so a
  # quick visit right as the agent finishes wouldn't clear the done icon.
  tmux set-option -w -t "${2:-}" @agent_status_seen "$(( $(date +%s) * 1000 + 999 ))" 2>/dev/null || true
  exit 0
fi

tmux_opt() {
  # tmux_opt <option> <default>
  local v
  v="$(tmux show-option -gqv "$1" 2>/dev/null || true)"
  [ -n "$v" ] && echo "$v" || echo "$2"
}

# --- User-tunable options (set with `set -g @... ...` in tmux.conf) ---
INTERVAL="$(tmux_opt @agent_status_interval 2)"
ICON_WORKING="$(tmux_opt @agent_status_working '🤖')"
ICON_WAITING="$(tmux_opt @agent_status_waiting '💬')"
ICON_DONE="$(tmux_opt @agent_status_done '✅')"
SET_FORMAT="$(tmux_opt @agent_status_set_format 1)"
RECENT_MARKER="$(tmux_opt @agent_status_recent_marker '•')"
RECENT_DAYS="$(tmux_opt @agent_status_recent_days 3)"
# tmux user-option the icon is written to.
STATUS_VAR="$(tmux_opt @agent_status_var @agent_status)"

# Teardown: `agent-status.tmux stop` — kill the daemon and clear our icons.
# (The format keeps a harmless empty `#{?@agent_status,...}` until next reload.)
if [ "${1:-}" = "stop" ] || [ "${1:-}" = "uninstall" ]; then
  pid="$(tmux show-option -gqv @agent_status_pid 2>/dev/null || true)"
  # Only kill if the recorded PID is actually our poller — a stale PID could
  # have been recycled by an unrelated process.
  if [ -n "$pid" ] && ps -p "$pid" -o command= 2>/dev/null | grep -q 'poller\.sh'; then
    kill "$pid" 2>/dev/null || true
  fi
  tmux set-option -gu @agent_status_pid 2>/dev/null || true
  tmux list-panes -a -F '#{pane_id}' 2>/dev/null | while read -r p; do
    tmux set-option -w -u -t "$p" "$STATUS_VAR" 2>/dev/null || true
    # Only wipe the seen/ts memory on a full uninstall. On a plain `stop` (used to
    # restart the daemon) keep them, or every finished window re-shows its ✅.
    if [ "${1:-}" = "uninstall" ]; then
      tmux set-option -w -u -t "$p" @agent_status_ts 2>/dev/null || true
      tmux set-option -w -u -t "$p" @agent_status_seen 2>/dev/null || true
    fi
  done
  # Remove ONLY our own seen-stamp hook(s), matched by this plugin's path, so we
  # never clobber unrelated after-select-window hooks. Unset highest index first
  # (tmux leaves the other indices untouched).
  tmux show-hooks -g 2>/dev/null \
    | grep -F "$CURRENT_DIR/agent-status.tmux' mark-seen" \
    | sed -n 's/^after-select-window\[\([0-9]\{1,\}\)\].*/\1/p' \
    | sort -rn \
    | while read -r _i; do
        tmux set-hook -gu "after-select-window[$_i]" 2>/dev/null || true
      done
  tmux set-option -gu @agent_status_hook_set 2>/dev/null || true
  exit 0
fi

# Wire the status icon into the window list. On by default. We *inject* the
# status slot into whatever window-status-format you already have (preserving
# custom theming) rather than overwriting it. If no format is set, fall back to
# a sensible default. Idempotent: skips if the var is already referenced.
inject_format() {
  local opt="$1" existing
  existing="$(tmux show-option -gqv "$opt" 2>/dev/null || true)"
  case "$existing" in
    *"$STATUS_VAR"*) return 0 ;; # already references our var
  esac
  if [ -z "$existing" ]; then
    tmux set-option -g "$opt" \
      "#I:#W#{?$STATUS_VAR, #{$STATUS_VAR},}#{?window_flags,#{window_flags}, }"
  else
    tmux set-option -g "$opt" "$existing#{?$STATUS_VAR, #{$STATUS_VAR},}"
  fi
}
if [ "$SET_FORMAT" = "1" ]; then
  inject_format window-status-format
  inject_format window-status-current-format
fi

# Stamp @agent_status_seen the instant a window is viewed, so a finished
# window's done icon clears even on a visit shorter than one poll interval.
# Appended (-ga) so we don't clobber a user's own after-select-window hook, and
# guarded by a marker so config reloads don't stack duplicates.
if [ -z "$(tmux show-option -gqv @agent_status_hook_set 2>/dev/null || true)" ]; then
  tmux set-hook -ga after-select-window \
    "run-shell -b \"bash '$CURRENT_DIR/agent-status.tmux' mark-seen '#{window_id}'\""
  tmux set-option -g @agent_status_hook_set 1
fi

# Single-instance guard: store the daemon PID in a server-global tmux option.
# If a live daemon is already recorded, do nothing.
EXISTING_PID="$(tmux show-option -gqv @agent_status_pid 2>/dev/null || true)"
if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
  exit 0
fi

# Launch the daemon detached. Pass the tmux socket so it targets this server
# even after tmux's env is gone. setsid if available so it survives the config
# reload that spawned it.
SOCKET="${TMUX%%,*}" # $TMUX = <socket>,<pid>,<session>

run_daemon() {
  AGENT_STATUS_SOCKET="$SOCKET" \
  AGENT_STATUS_INTERVAL="$INTERVAL" \
  AGENT_STATUS_VAR="$STATUS_VAR" \
  AGENT_STATUS_ICON_WORKING="$ICON_WORKING" \
  AGENT_STATUS_ICON_WAITING="$ICON_WAITING" \
  AGENT_STATUS_ICON_DONE="$ICON_DONE" \
  AGENT_STATUS_RECENT_MARKER="$RECENT_MARKER" \
  AGENT_STATUS_RECENT_DAYS="$RECENT_DAYS" \
  exec bash "$POLLER"
}

# Export everything run_daemon references so the detached child inherits it. The
# `setsid bash -c` path starts a FRESH shell that only receives the serialized
# function body — without these exports POLLER/SOCKET/… would be empty there and
# the daemon would exec an empty path.
export POLLER SOCKET INTERVAL STATUS_VAR \
  ICON_WORKING ICON_WAITING ICON_DONE RECENT_MARKER RECENT_DAYS

if command -v setsid >/dev/null 2>&1; then
  setsid bash -c "$(declare -f run_daemon); run_daemon" >/dev/null 2>&1 &
else
  ( run_daemon ) >/dev/null 2>&1 &
fi

DAEMON_PID=$!
disown "$DAEMON_PID" 2>/dev/null || true
tmux set-option -g @agent_status_pid "$DAEMON_PID"
