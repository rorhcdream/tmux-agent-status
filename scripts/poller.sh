#!/usr/bin/env bash
# Background daemon: reads per-session status for the coding agent running in
# each tmux pane and drives a tmux status option (default @agent_status). Two
# agents are supported, each with its own storage model:
#   claude -> ~/.claude*/sessions/<pid>.json  (explicit status, keyed by pid)
#   codex  -> ~/.codex/sessions/.../rollout-*.jsonl  (status derived from the
#             append-only event log; pid bridged to its file via lsof, cached)
# Both feed the same icon state machine below. No agent hooks required.
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
#   AGENT_STATUS_SOCKET, AGENT_STATUS_INTERVAL, AGENT_STATUS_VAR,
#   AGENT_STATUS_ICON_WORKING/WAITING/DONE,
#   AGENT_STATUS_RECENT_MARKER, AGENT_STATUS_RECENT_DAYS

set -uo pipefail

SOCKET="${AGENT_STATUS_SOCKET:-}"
INTERVAL="${AGENT_STATUS_INTERVAL:-2}"
STATUS_VAR="${AGENT_STATUS_VAR:-@agent_status}"
ICON_WORKING="${AGENT_STATUS_ICON_WORKING:-🤖}"
ICON_WAITING="${AGENT_STATUS_ICON_WAITING:-💬}"
ICON_DONE="${AGENT_STATUS_ICON_DONE:-✅}"
RECENT_MARKER="${AGENT_STATUS_RECENT_MARKER:-•}"
RECENT_DAYS="${AGENT_STATUS_RECENT_DAYS:-3}"

# Claude config dirs to scan for sessions/<pid>.json (space-separated). When
# Claude runs under more than one config dir (via CLAUDE_CONFIG_DIR), session
# files are split across them, so this global daemon watches them ALL. We
# deliberately do NOT restrict to the launching shell's CLAUDE_CONFIG_DIR: the
# daemon is server-wide and must cover every config, not just whichever one
# happened to spawn it. Set AGENT_STATUS_CONFIG_DIRS to override with an
# explicit space-separated list.
CONFIG_DIRS="${AGENT_STATUS_CONFIG_DIRS:-}"
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

# Find ALL `claude`/`codex` processes at or beneath the given pid (BFS,
# depth-limited). Echoes one "<pid>\t<kind>" line per agent (kind claude|codex).
# A single pane can host more than one agent (e.g. a claude and a codex side by
# side); the caller aggregates their statuses. We don't descend into an agent's
# own subtree (an agent's children aren't separate sessions).
find_agent_pids() {
  local root="$1" depth=0 max=6 found=1
  local -a frontier=("$root") next=()
  while [ "${#frontier[@]}" -gt 0 ] && [ "$depth" -lt "$max" ]; do
    next=()
    local p child comm
    for p in "${frontier[@]}"; do
      comm="${COMM_OF[$p]:-}"
      if [ "$comm" = "claude" ] || [ "$comm" = "codex" ]; then
        printf '%s\t%s\n' "$p" "$comm"; found=0
        continue
      fi
      for child in "${!PPID_OF[@]}"; do
        [ "${PPID_OF[$child]}" = "$p" ] && next+=("$child")
      done
    done
    frontier=("${next[@]+"${next[@]}"}")
    depth=$((depth + 1))
  done
  return "$found"
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

# --- Codex support -----------------------------------------------------------
# Codex stores each session as an append-only event log at
# ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl, named by timestamp and
# UUID (no pid). We bridge a running codex pid to its rollout via the file it
# holds open (lsof), then cache pid->file for the process's lifetime so the
# mapping survives the handle being closed between turns (keeps the sticky done
# icon working). Status is derived from the last turn-boundary event.
declare -A CODEX_FILE_OF   # codex pid -> rollout jsonl path (cached)

codex_file_for_pid() {
  local pid="$1" f
  f="${CODEX_FILE_OF[$pid]:-}"
  [ -n "$f" ] && [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  # Locate the rollout .jsonl the codex process currently holds open.
  f="$(lsof -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' \
        | grep -m1 -E '/sessions/.*/rollout-.*\.jsonl$')"
  [ -n "$f" ] && [ -f "$f" ] && { CODEX_FILE_OF["$pid"]="$f"; printf '%s' "$f"; return 0; }
  return 1
}

# Echoes "<status>\t<ts_ms>" for a codex pid, derived from the rollout tail:
#   task_started (no later task_complete) -> busy;  task_complete -> idle;
#   turn_aborted -> cleared. ts comes from the boundary event's ISO timestamp.
status_for_codex_pid() {
  local pid="$1" f out ev tsms st=""
  f="$(codex_file_for_pid "$pid")" || { printf '\t0'; return; }
  # One jq pass over the tail: take the LAST turn-boundary event, emit
  # "<type>\t<epoch_ms>" (ms parsed from its ISO8601 .timestamp).
  out="$(tail -n 80 "$f" 2>/dev/null | jq -rs '
    ([ .[]
       | {t: (.payload.type // .type // ""), ts: (.timestamp // "")}
       | select(.t=="task_started" or .t=="task_complete" or .t=="turn_aborted") ]
     | last) as $e
    | if $e == null then empty
      else $e.t + "\t"
        + ((try (($e.ts | sub("\\.[0-9]+";"") | fromdateiso8601) * 1000) catch 0) | tostring)
      end' 2>/dev/null)"
  [ -n "$out" ] || { printf '\t0'; return; }
  ev="${out%%$'\t'*}"
  tsms="${out#*$'\t'}"
  case "$ev" in
    task_started)  st="busy" ;;
    task_complete) st="idle" ;;
    *)             st="" ;;
  esac
  case "$tsms" in ''|0|null) tsms="$(file_mtime "$f")000"; [ "$tsms" = "000" ] && tsms=0 ;; esac
  printf '%s\t%s' "$st" "$tsms"
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

  # Drop cached codex rollout handles for processes that have exited.
  local _p
  for _p in "${!CODEX_FILE_OF[@]}"; do
    [ -n "${PPID_OF[$_p]:-}" ] || unset 'CODEX_FILE_OF[$_p]'
  done

  local now_ms thr_ms
  now_ms=$(( $(date +%s) * 1000 ))
  thr_ms=$(( RECENT_DAYS * 86400 * 1000 ))

  local pane pane_pid pane_active win_active current
  local st ts base viewing final seen
  local apid akind ast ats rank best win_st win_ts

  while IFS=$'\t' read -r pane pane_pid pane_active win_active current; do
    [ -z "${pane:-}" ] && continue
    base=""; ts=0
    viewing=0; [ "$win_active" = "1" ] && viewing=1

    # A pane may host several agents (e.g. a claude and a codex side by side).
    # Report the MOST ACTIVE one — precedence busy/shell > waiting > idle, with
    # the more recent ts breaking ties. Without this an idle codex could blank
    # the icon of a busy claude sharing the window (and vice versa).
    win_st=""; win_ts=0; best=0
    while IFS=$'\t' read -r apid akind; do
      [ -z "${apid:-}" ] && continue
      if [ "$akind" = "codex" ]; then
        IFS=$'\t' read -r ast ats < <(status_for_codex_pid "$apid")
      else
        IFS=$'\t' read -r ast ats < <(status_for_pid "$apid")
      fi
      case "$ast" in
        busy|shell) rank=3 ;;
        waiting)    rank=2 ;;
        idle)       rank=1 ;;
        *)          rank=0 ;;
      esac
      if [ "$rank" -gt "$best" ] \
        || { [ "$rank" -eq "$best" ] && [ "${ats:-0}" -gt "${win_ts:-0}" ] 2>/dev/null; }; then
        best="$rank"; win_st="$ast"; win_ts="${ats:-0}"
      fi
    done < <(find_agent_pids "$pane_pid")

    st="$win_st"; ts="${win_ts:-0}"
    if [ -n "$st" ]; then
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
          # (@agent_status_seen) stamped by the after-select-window hook the
          # moment you view a window — so it survives quick visits the 2s poll
          # would otherwise miss, and daemon restarts. We also stamp it here
          # while you're actively viewing (covers completing while watched).
          seen="$(tm show-option -wqv -t "$pane" @agent_status_seen 2>/dev/null)"
          seen="${seen:-0}"
          if [ "$viewing" = "1" ]; then
            tm set-option -w -t "$pane" @agent_status_seen "$ts" >/dev/null 2>&1 || true
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
      [ "$(tm show-option -wqv -t "$pane" @agent_status_ts 2>/dev/null)" = "$ts" ] \
        || tm set-option -w -t "$pane" @agent_status_ts "$ts" >/dev/null 2>&1 || true
    else
      tm set-option -w -u -t "$pane" @agent_status_ts >/dev/null 2>&1 || true
    fi
  done < <(tm list-panes -a -F "#{pane_id}	#{pane_pid}	#{pane_active}	#{window_active}	#{$STATUS_VAR}" 2>/dev/null)
}

# One-shot mode: reconcile once and exit (for testing / manual refresh).
if [ -n "${AGENT_STATUS_ONESHOT:-}" ]; then
  reconcile
  exit 0
fi

# Clean up our recorded PID on exit.
trap 'tm set-option -gu @agent_status_pid >/dev/null 2>&1 || true' EXIT

while true; do
  server_alive || exit 0
  reconcile
  sleep "$INTERVAL"
done
