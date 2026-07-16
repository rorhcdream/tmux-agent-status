#!/usr/bin/env bash
# Background daemon: reads Claude Code's per-session status from
# ~/.claude/sessions/<pid>.json and drives a tmux status option (default
# @claude_status) for the pane each Claude process runs in. No Claude hooks.
#
# Status mapping:
#   busy | shell  -> working icon
#   waiting       -> waiting icon (shown until you view the window)
#   idle          -> done icon, STICKY: shown until you view the window once;
#                    stays cleared until the next completion
#   (no claude)   -> cleared
#
# Recency marker: sessions whose last status change is within RECENT_DAYS get a
# small marker appended to their icon (e.g. "✅ •"); older sessions show the bare
# icon. Set RECENT_DAYS to 0 (or an empty marker) to disable.
#
# Configured via env vars set by the .tmux entry script:
#   CLAUDE_STATUS_SOCKET, CLAUDE_STATUS_INTERVAL, CLAUDE_STATUS_VAR,
#   CLAUDE_STATUS_ICON_WORKING/WAITING/DONE,
#   CLAUDE_STATUS_RECENT_MARKER, CLAUDE_STATUS_RECENT_DAYS

set -uo pipefail

SOCKET="${CLAUDE_STATUS_SOCKET:-}"
INTERVAL="${CLAUDE_STATUS_INTERVAL:-2}"
STATUS_VAR="${CLAUDE_STATUS_VAR:-@claude_status}"
ICON_WORKING="${CLAUDE_STATUS_ICON_WORKING:-🤖}"
ICON_WAITING="${CLAUDE_STATUS_ICON_WAITING:-💬}"
ICON_DONE="${CLAUDE_STATUS_ICON_DONE:-✅}"
RECENT_MARKER="${CLAUDE_STATUS_RECENT_MARKER:-•}"
RECENT_DAYS="${CLAUDE_STATUS_RECENT_DAYS:-3}"

# Claude config dirs to scan for sessions/<pid>.json (space-separated). When
# Claude runs under more than one config dir (via CLAUDE_CONFIG_DIR), session
# files are split across them, so this global daemon watches them ALL. We
# deliberately do NOT restrict to the launching shell's CLAUDE_CONFIG_DIR: the
# daemon is server-wide and must cover every config, not just whichever one
# happened to spawn it. Set CLAUDE_STATUS_CONFIG_DIRS to override with an
# explicit space-separated list.
CONFIG_DIRS="${CLAUDE_STATUS_CONFIG_DIRS:-}"
if [ -z "$CONFIG_DIRS" ]; then
  # Every ~/.claude*/ that actually has a sessions/ dir.
  for _d in "$HOME"/.claude*/; do
    [ -d "${_d}sessions" ] && CONFIG_DIRS="$CONFIG_DIRS ${_d%/}"
  done
  # Also include a non-standard CLAUDE_CONFIG_DIR if the glob above missed it.
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    case " $CONFIG_DIRS " in
      *" ${CLAUDE_CONFIG_DIR%/} "*) : ;;
      *) CONFIG_DIRS="$CONFIG_DIRS ${CLAUDE_CONFIG_DIR%/}" ;;
    esac
  fi
  CONFIG_DIRS="${CONFIG_DIRS# }"
  [ -z "$CONFIG_DIRS" ] && CONFIG_DIRS="$HOME/.claude"
fi

tm() {
  if [ -n "$SOCKET" ]; then tmux -S "$SOCKET" "$@"; else tmux "$@"; fi
}

# Exit cleanly if the tmux server goes away.
server_alive() { tm has-session >/dev/null 2>&1 || tm list-panes -a >/dev/null 2>&1; }

file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

declare -A PPID_OF       # pid -> ppid
declare -A COMM_OF       # pid -> basename(comm)

snapshot_processes() {
  PPID_OF=(); COMM_OF=()
  local pid ppid comm
  while read -r pid ppid comm; do
    [ -z "${pid:-}" ] && continue
    PPID_OF["$pid"]="$ppid"
    COMM_OF["$pid"]="${comm##*/}"
  done < <(ps -Ao pid=,ppid=,comm= 2>/dev/null)
}

# Find a `claude` process at or beneath the given pid (BFS, depth-limited).
find_claude_pid() {
  local root="$1" depth=0 max=6
  local -a frontier=("$root") next=()
  while [ "${#frontier[@]}" -gt 0 ] && [ "$depth" -lt "$max" ]; do
    next=()
    local p child
    for p in "${frontier[@]}"; do
      [ "${COMM_OF[$p]:-}" = "claude" ] && { echo "$p"; return 0; }
      for child in "${!PPID_OF[@]}"; do
        [ "${PPID_OF[$child]}" = "$p" ] && next+=("$child")
      done
    done
    frontier=("${next[@]+"${next[@]}"}")
    depth=$((depth + 1))
  done
  return 1
}

# Echoes "<status>\t<ts_ms>" for a Claude pid; ts falls back to file mtime.
# Scans every config dir; if the same pid.json exists in several (pid reuse
# across configs), the freshest mtime wins — the stale one is a dead session.
status_for_pid() {
  local pid="$1"
  local d cand f="" best=0 m
  for d in $CONFIG_DIRS; do
    cand="$d/sessions/$pid.json"
    [ -f "$cand" ] || continue
    m="$(file_mtime "$cand")"
    [ "${m:-0}" -gt "$best" ] 2>/dev/null && { best="$m"; f="$cand"; }
  done
  local out s ts
  [ -n "$f" ] || { printf '\t0'; return; }
  out="$(jq -r '[(.status // ""), ((.statusUpdatedAt // .updatedAt) // 0)] | @tsv' "$f" 2>/dev/null)"
  s="${out%%$'\t'*}"
  ts="${out#*$'\t'}"
  case "$ts" in ''|0|null) ts="$(file_mtime "$f")000"; [ "$ts" = "000" ] && ts=0 ;; esac
  printf '%s\t%s' "$s" "$ts"
}

set_pane_status() {
  # set_pane_status <pane_id> <current> <desired>
  local pane="$1" current="$2" desired="$3"
  [ "$current" = "$desired" ] && return 0
  if [ -z "$desired" ]; then
    tm set-option -w -u -t "$pane" "$STATUS_VAR" >/dev/null 2>&1 || true
  else
    tm set-option -w -t "$pane" "$STATUS_VAR" "$desired" >/dev/null 2>&1 || true
  fi
}

reconcile() {
  snapshot_processes

  local now_ms thr_ms
  now_ms=$(( $(date +%s) * 1000 ))
  thr_ms=$(( RECENT_DAYS * 86400 * 1000 ))

  local pane pane_pid pane_active win_active current
  local cpid st ts base viewing final seen

  while IFS=$'\t' read -r pane pane_pid pane_active win_active current; do
    [ -z "${pane:-}" ] && continue
    base=""; ts=0
    viewing=0; [ "$win_active" = "1" ] && viewing=1

    if cpid="$(find_claude_pid "$pane_pid")"; then
      IFS=$'\t' read -r st ts < <(status_for_pid "$cpid")
      case "$st" in
        busy|shell) base="$ICON_WORKING" ;;
        waiting)
          # Urgent: show until viewed; re-show if still waiting after you leave.
          [ "$viewing" = "1" ] && base="" || base="$ICON_WAITING"
          ;;
        idle)
          # Sticky done: cleared once the window has been viewed at/after this
          # completion, and stays cleared until a NEW completion (newer
          # statusUpdatedAt) arrives. "Seen" is a per-window tmux option
          # (@claude_status_seen) stamped by the after-select-window hook the
          # moment you view a window — so it survives quick visits the 2s poll
          # would otherwise miss, and daemon restarts. We also stamp it here
          # while you're actively viewing (covers completing while watched).
          seen="$(tm show-option -wqv -t "$pane" @claude_status_seen 2>/dev/null)"
          seen="${seen:-0}"
          if [ "$viewing" = "1" ]; then
            tm set-option -w -t "$pane" @claude_status_seen "$ts" >/dev/null 2>&1 || true
            base=""
          elif [ "$seen" -ge "$ts" ] 2>/dev/null; then
            base=""
          else
            base="$ICON_DONE"
          fi
          ;;
      esac
    fi

    # Compose final icon, appending the recency marker for sessions active
    # within RECENT_DAYS.
    if [ -z "$base" ]; then
      final=""
    elif [ -n "$RECENT_MARKER" ] && [ "$RECENT_DAYS" -gt 0 ] \
      && [ "$ts" -gt 0 ] && [ $(( now_ms - ts )) -le "$thr_ms" ]; then
      final="$base $RECENT_MARKER"
    else
      final="$base"
    fi
    set_pane_status "$pane" "$current" "$final"
    # Publish the status timestamp (statusUpdatedAt = finish time when done,
    # trigger time when working) so consumers can sort by it. Unlike
    # window_activity it does NOT churn while a session keeps running.
    if [ -n "$base" ] && [ "$ts" -gt 0 ] 2>/dev/null; then
      [ "$(tm show-option -wqv -t "$pane" @claude_status_ts 2>/dev/null)" = "$ts" ] \
        || tm set-option -w -t "$pane" @claude_status_ts "$ts" >/dev/null 2>&1 || true
    else
      tm set-option -w -u -t "$pane" @claude_status_ts >/dev/null 2>&1 || true
    fi
  done < <(tm list-panes -a -F "#{pane_id}	#{pane_pid}	#{pane_active}	#{window_active}	#{$STATUS_VAR}" 2>/dev/null)
}

# One-shot mode: reconcile once and exit (for testing / manual refresh).
if [ -n "${CLAUDE_STATUS_ONESHOT:-}" ]; then
  reconcile
  exit 0
fi

# Clean up our recorded PID on exit.
trap 'tm set-option -gu @claude_status_pid >/dev/null 2>&1 || true' EXIT

while true; do
  server_alive || exit 0
  reconcile
  sleep "$INTERVAL"
done
