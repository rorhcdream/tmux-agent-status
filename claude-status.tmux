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
  tmux set-option -w -t "${2:-}" @claude_status_seen "$(( $(date +%s) * 1000 + 999 ))" 2>/dev/null || true
  exit 0
fi

tmux_opt() {
  # tmux_opt <option> <default>
  local v
  v="$(tmux show-option -gqv "$1" 2>/dev/null || true)"
  [ -n "$v" ] && echo "$v" || echo "$2"
}

# --- User-tunable options (set with `set -g @... ...` in tmux.conf) ---
INTERVAL="$(tmux_opt @claude_status_interval 2)"
ICON_WORKING="$(tmux_opt @claude_status_working '🤖')"
ICON_WAITING="$(tmux_opt @claude_status_waiting '💬')"
ICON_DONE="$(tmux_opt @claude_status_done '✅')"
SET_FORMAT="$(tmux_opt @claude_status_set_format 1)"
RECENT_MARKER="$(tmux_opt @claude_status_recent_marker '•')"
RECENT_DAYS="$(tmux_opt @claude_status_recent_days 3)"
# tmux user-option the icon is written to.
STATUS_VAR="$(tmux_opt @claude_status_var @claude_status)"

# Teardown: `claude-status.tmux stop` — kill the daemon and clear our icons.
# (The format keeps a harmless empty `#{?@claude_status,...}` until next reload.)
if [ "${1:-}" = "stop" ] || [ "${1:-}" = "uninstall" ]; then
  pid="$(tmux show-option -gqv @claude_status_pid 2>/dev/null || true)"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  tmux set-option -gu @claude_status_pid 2>/dev/null || true
  tmux list-panes -a -F '#{pane_id}' 2>/dev/null | while read -r p; do
    tmux set-option -w -u -t "$p" "$STATUS_VAR" 2>/dev/null || true
    # Only wipe the seen/ts memory on a full uninstall. On a plain `stop` (used to
    # restart the daemon) keep them, or every finished window re-shows its ✅.
    if [ "${1:-}" = "uninstall" ]; then
      tmux set-option -w -u -t "$p" @claude_status_ts 2>/dev/null || true
      tmux set-option -w -u -t "$p" @claude_status_seen 2>/dev/null || true
    fi
  done
  # Remove the seen-stamp hook. NOTE: -u drops ALL after-select-window hooks;
  # fine for this plugin's use, but re-add any of your own after uninstalling.
  tmux set-hook -gu after-select-window 2>/dev/null || true
  tmux set-option -gu @claude_status_hook_set 2>/dev/null || true
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

# Stamp @claude_status_seen the instant a window is viewed, so a finished
# window's done icon clears even on a visit shorter than one poll interval.
# Appended (-ga) so we don't clobber a user's own after-select-window hook, and
# guarded by a marker so config reloads don't stack duplicates.
if [ -z "$(tmux show-option -gqv @claude_status_hook_set 2>/dev/null || true)" ]; then
  tmux set-hook -ga after-select-window \
    "run-shell -b \"bash '$CURRENT_DIR/claude-status.tmux' mark-seen '#{window_id}'\""
  tmux set-option -g @claude_status_hook_set 1
fi

# Single-instance guard: store the daemon PID in a server-global tmux option.
# If a live daemon is already recorded, do nothing.
EXISTING_PID="$(tmux show-option -gqv @claude_status_pid 2>/dev/null || true)"
if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
  exit 0
fi

# Launch the daemon detached. Pass the tmux socket so it targets this server
# even after tmux's env is gone. setsid if available so it survives the config
# reload that spawned it.
SOCKET="${TMUX%%,*}" # $TMUX = <socket>,<pid>,<session>

run_daemon() {
  CLAUDE_STATUS_SOCKET="$SOCKET" \
  CLAUDE_STATUS_INTERVAL="$INTERVAL" \
  CLAUDE_STATUS_VAR="$STATUS_VAR" \
  CLAUDE_STATUS_ICON_WORKING="$ICON_WORKING" \
  CLAUDE_STATUS_ICON_WAITING="$ICON_WAITING" \
  CLAUDE_STATUS_ICON_DONE="$ICON_DONE" \
  CLAUDE_STATUS_RECENT_MARKER="$RECENT_MARKER" \
  CLAUDE_STATUS_RECENT_DAYS="$RECENT_DAYS" \
  exec bash "$POLLER"
}

if command -v setsid >/dev/null 2>&1; then
  setsid bash -c "$(declare -f run_daemon); run_daemon" >/dev/null 2>&1 &
else
  ( run_daemon ) >/dev/null 2>&1 &
fi

DAEMON_PID=$!
disown "$DAEMON_PID" 2>/dev/null || true
tmux set-option -g @claude_status_pid "$DAEMON_PID"
