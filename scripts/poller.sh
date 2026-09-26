#!/usr/bin/env bash
# Background daemon: reads per-session status for the coding agent running in
# each tmux pane and drives a per-window status option (default @agent_status)
# plus a per-session summary (default @agent_status_summary). Two agents are
# supported, each with its own storage model:
#   claude -> ~/.claude*/sessions/<pid>.json  (explicit status, keyed by pid)
#   codex  -> ~/.codex/sessions/.../rollout-*.jsonl  (status derived from the
#             append-only event log; pid bridged to its file via lsof, cached)
# Both feed the same icon state machine below. No agent hooks required.
#
# Status mapping:
#   busy | shell  -> working icon
#   waiting       -> waiting icon (shown until the agent leaves waiting state)
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
#   AGENT_STATUS_SUMMARY_VAR,
#   AGENT_STATUS_ICON_WORKING/WAITING/DONE,
#   AGENT_STATUS_RECENT_MARKER, AGENT_STATUS_RECENT_DAYS

set -uo pipefail

SOCKET="${AGENT_STATUS_SOCKET:-}"
INTERVAL="${AGENT_STATUS_INTERVAL:-0.5}"
STATUS_VAR="${AGENT_STATUS_VAR:-@agent_status}"
SUMMARY_VAR="${AGENT_STATUS_SUMMARY_VAR:-@agent_status_summary}"
ICON_WORKING="${AGENT_STATUS_ICON_WORKING:-🤖}"
ICON_WAITING="${AGENT_STATUS_ICON_WAITING:-💬}"
ICON_DONE="${AGENT_STATUS_ICON_DONE:-✅}"
RECENT_MARKER="${AGENT_STATUS_RECENT_MARKER:-•}"
RECENT_DAYS="${AGENT_STATUS_RECENT_DAYS:-3}"

# Guard the numeric settings so a bad tmux-option value can't break `sleep`
# (INTERVAL, positive integer or decimal) or integer arithmetic (RECENT_DAYS).
case "$INTERVAL" in
  ''|*[!0-9.]*|*.*.*|.*|*.) INTERVAL=0.5 ;;
esac
case "$RECENT_DAYS" in ''|*[!0-9]*) RECENT_DAYS=3 ;; esac

# Convert the cadence once so refresh time can be subtracted from each sleep.
# Sub-second timing needs EPOCHREALTIME, which is Bash 5+; the rest of this
# script only needs Bash 4 (associative arrays). On Bash 4 the variable is unset
# and every caller falls back to a plain sleep of the full interval.
_interval_whole="${INTERVAL%%.*}"
if [ "$INTERVAL" = "$_interval_whole" ]; then
  _interval_fraction=000000
else
  _interval_fraction="${INTERVAL#*.}000000"
  _interval_fraction="${_interval_fraction:0:6}"
fi
INTERVAL_US=$(( 10#$_interval_whole * 1000000 + 10#$_interval_fraction ))
[ "$INTERVAL_US" -gt 0 ] || { INTERVAL=0.5; INTERVAL_US=500000; }

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

file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

declare -A PPID_OF       # pid -> ppid
declare -A COMM_OF       # pid -> basename(comm)
declare -A CHILDREN_OF   # ppid -> space-separated child pids
declare -A PANE_CODEX_PID # codex pids discovered below a tmux pane
declare -A CODEX_CWD_OF_PID # codex pid -> cwd ("-" if unknown), per process snapshot
HAS_CODEX_PROCESS=0
PROCESS_SNAPSHOT_AT_US=0
CODEX_SNAPSHOT_AT_US=0
PANE_PROCESS_FINGERPRINT=""
PROCESS_SNAPSHOT_TTL_US=5000000 # safety rescan; pane command changes are immediate
CODEX_SNAPSHOT_TTL_US=2000000   # catches resumed pre-existing rollouts

snapshot_processes() {
  PPID_OF=(); COMM_OF=(); CHILDREN_OF=(); HAS_CODEX_PROCESS=0
  local pid ppid comm
  while read -r pid ppid comm; do
    [ -z "${pid:-}" ] && continue
    PPID_OF["$pid"]="$ppid"
    COMM_OF["$pid"]="${comm##*/}"
    CHILDREN_OF["$ppid"]+="${CHILDREN_OF[$ppid]:+ }$pid"
    [ "${comm##*/}" = codex ] && HAS_CODEX_PROCESS=1
  done < <(ps -Ao pid=,ppid=,comm= 2>/dev/null)
}

# Find ALL `claude`/`codex` processes at or beneath the given pid (BFS,
# depth-limited). Echoes one "<pid>\t<kind>" line per agent (kind claude|codex).
# A single pane can host more than one agent (e.g. a claude and a codex side by
# side); the caller aggregates their statuses. We don't descend into an agent's
# own subtree (an agent's children aren't separate sessions).
find_agent_pids() {
  # find_agent_pids <root-pid> <output-variable>
  local root="$1" output_var="$2" depth=0 max=6 found=1 result=""
  if [ -z "$root" ]; then
    printf -v "$output_var" ''
    return 1
  fi
  local -a frontier=("$root") next=()
  while [ "${#frontier[@]}" -gt 0 ] && [ "$depth" -lt "$max" ]; do
    next=()
    local p child comm
    for p in "${frontier[@]}"; do
      comm="${COMM_OF[$p]:-}"
      if [ "$comm" = "claude" ] || [ "$comm" = "codex" ]; then
        result+="${result:+$'\n'}$p"$'\t'"$comm"; found=0
        continue
      fi
      for child in ${CHILDREN_OF[$p]:-}; do
        next+=("$child")
      done
    done
    frontier=("${next[@]+"${next[@]}"}")
    depth=$((depth + 1))
  done
  printf -v "$output_var" '%s' "$result"
  return "$found"
}

snapshot_pane_codex_pids() {
  local pane_snapshot="$1" pane window session index pane_pid rest agent_pids apid akind
  PANE_CODEX_PID=()
  while IFS=$'\t' read -r pane window session index pane_pid rest; do
    [ -n "${pane_pid:-}" ] || continue
    agent_pids=""
    find_agent_pids "$pane_pid" agent_pids || true
    while IFS=$'\t' read -r apid akind; do
      [ "$akind" = codex ] && PANE_CODEX_PID["$apid"]=1
    done <<< "$agent_pids"
  done <<< "$pane_snapshot"
  return 0
}

# Returns status and ts_ms for a Claude pid; ts falls back to file mtime.
# Scans every config dir; if the same pid.json exists in several (pid reuse
# across configs), the freshest mtime wins — the stale one is a dead session.
declare -A CLAUDE_FILE_OF     # claude pid -> selected session file
declare -A CLAUDE_CONTENT_OF  # session file -> exact content at last parse
declare -A CLAUDE_STATUS_OF   # session file -> last parsed status
declare -A CLAUDE_TS_OF       # session file -> last parsed timestamp

status_for_pid() {
  # status_for_pid <pid> <status-variable> <timestamp-variable>
  local pid="$1" status_var="$2" timestamp_var="$3"
  local d cand f="" best=0 m
  f="${CLAUDE_FILE_OF[$pid]:-}"
  if [ ! -f "$f" ]; then
    f=""
    for d in $CONFIG_DIRS; do
      cand="$d/sessions/$pid.json"
      [ -f "$cand" ] || continue
      m="$(file_mtime "$cand")"
      [ "${m:-0}" -gt "$best" ] 2>/dev/null && { best="$m"; f="$cand"; }
    done
    if [ -n "$f" ]; then
      CLAUDE_FILE_OF["$pid"]="$f"
    else
      unset 'CLAUDE_FILE_OF[$pid]'
      printf -v "$status_var" ''
      printf -v "$timestamp_var" '0'
      return
    fi
  fi

  local content out s ts
  content="$(< "$f")"
  if [ "${CLAUDE_CONTENT_OF[$f]+set}" = set ] \
    && [ "${CLAUDE_CONTENT_OF[$f]}" = "$content" ]; then
    printf -v "$status_var" '%s' "${CLAUDE_STATUS_OF[$f]:-}"
    printf -v "$timestamp_var" '%s' "${CLAUDE_TS_OF[$f]:-0}"
    return
  fi

  out="$(jq -r '[(.status // ""), ((.statusUpdatedAt // .updatedAt) // 0)] | @tsv' <<< "$content" 2>/dev/null)"
  s="${out%%$'\t'*}"
  ts="${out#*$'\t'}"
  case "$ts" in ''|0|null) ts="$(file_mtime "$f")000"; [ "$ts" = "000" ] && ts=0 ;; esac
  CLAUDE_CONTENT_OF["$f"]="$content"
  CLAUDE_STATUS_OF["$f"]="$s"
  CLAUDE_TS_OF["$f"]="$ts"
  printf -v "$status_var" '%s' "$s"
  printf -v "$timestamp_var" '%s' "$ts"
}

# --- Codex support -----------------------------------------------------------
# Codex stores each session as an append-only event log at
# ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl, named by timestamp and
# UUID (no pid). We bridge a running codex pid to every rollout file it holds
# open (lsof). A resumed or multi-agent process can keep several live rollouts,
# so their states are aggregated with working > done instead of allowing the
# most recently written completion to hide another running turn. We cache the
# set per pid so status survives handles closing briefly between turns.
declare -A CODEX_FILES_OF   # codex pid -> newline-separated rollout paths
declare -A CODEX_FILE_PID_OF # rollout path -> owning codex pid
declare -A CODEX_KNOWN_OF    # rollout path -> 1 once its history has been seeded
declare -A CODEX_STATUS_OF   # rollout path -> last derived status
declare -A CODEX_TS_OF       # rollout path -> last boundary timestamp
declare -A CODEX_SIZE_OF     # rollout path -> size after last parse
declare -A CODEX_OPEN_FILES_OF # codex pid -> rollouts open this poll
declare -A CODEX_OPEN_OWNER_OF # rollout path -> pid holding it open
declare -A CODEX_SIZE_SNAPSHOT_OF # rollout path -> size in this poll
CODEX_ALL_OPEN_FILES=""      # unique rollouts held by any Codex process
declare -A CODEX_META_KNOWN_OF # rollout path -> 1 once session metadata was read
declare -A CODEX_CWD_OF       # rollout path -> session working directory
declare -A CODEX_ID_OF        # rollout path -> thread id
declare -A CODEX_SESSION_OF   # rollout path -> root session id
declare -A CODEX_PARENT_OF    # rollout path -> parent thread id (empty for root)
declare -A CODEX_SUBAGENT_OF  # rollout path -> 1 when source marks a subagent

if stat -c %s "$0" >/dev/null 2>&1; then
  STAT_SIZE_STYLE=gnu
else
  STAT_SIZE_STYLE=bsd
fi

# Snapshot open rollout handles for every Codex process with one lsof call.
# Running lsof separately for each pane was the largest avoidable polling cost.
snapshot_codex_files() {
  CODEX_OPEN_FILES_OF=()
  CODEX_OPEN_OWNER_OF=()
  CODEX_ALL_OPEN_FILES=""
  [ "$HAS_CODEX_PROCESS" = 1 ] || return
  local line pid="" candidate
  local -A seen=()
  while IFS= read -r line; do
    case "$line" in
      p*) pid="${line#p}" ;;
      n*/sessions/*/rollout-*.jsonl)
        candidate="${line#n}"
        [ -n "$pid" ] && [ -f "$candidate" ] || continue
        CODEX_OPEN_FILES_OF["$pid"]+="${CODEX_OPEN_FILES_OF[$pid]:+$'\n'}$candidate"
        CODEX_OPEN_OWNER_OF["$candidate"]="$pid"
        if [ -z "${seen[$candidate]:-}" ]; then
          seen["$candidate"]=1
          CODEX_ALL_OPEN_FILES+="${CODEX_ALL_OPEN_FILES:+$'\n'}$candidate"
        fi
        ;;
    esac
  done < <(lsof -a -c codex -Fn 2>/dev/null)
}

# Cached per process snapshot: the shared fallback runs every poll and compares
# every pane client's cwd, which would otherwise fork (lsof on macOS) n^2 times.
codex_cached_cwd_for_pid() {
  # codex_cached_cwd_for_pid <pid> <output-variable>
  local _cached_cwd="${CODEX_CWD_OF_PID[$1]:-}"
  if [ -z "$_cached_cwd" ]; then
    _cached_cwd="$(codex_cwd_for_pid "$1")"
    CODEX_CWD_OF_PID["$1"]="${_cached_cwd:--}"
  fi
  [ "$_cached_cwd" = - ] && _cached_cwd=""
  printf -v "$2" '%s' "$_cached_cwd"
}

codex_cwd_for_pid() {
  local cwd
  cwd="$(readlink "/proc/$1/cwd" 2>/dev/null)"
  if [ -n "$cwd" ]; then
    printf '%s\n' "$cwd"
    return
  fi
  # macOS has no /proc. lsof reports the process's cwd as an n-prefixed path.
  lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n\(\/.*\)$/\1/p' | head -n 1
}

codex_metadata_for_file() {
  local codex_file="$1" out
  [ -n "${CODEX_META_KNOWN_OF[$codex_file]:-}" ] && return
  out="$(head -n 32 "$codex_file" 2>/dev/null | jq -Rrn '
    first(inputs | fromjson? | select(.type == "session_meta") | .payload) as $m
    | if $m == null then empty
      else [($m.cwd // "-"), ($m.id // "-"), ($m.session_id // "-"),
            ($m.parent_thread_id // (try $m.source.subagent.thread_spawn.parent_thread_id catch null) // "-"),
            (if $m.thread_source == "subagent" or (try $m.source.subagent catch null) != null
             then "1" else "0" end)] | @tsv
      end' 2>/dev/null)"
  # A newly opened rollout may be observed before session_meta is complete.
  # Leave it uncached so the next snapshot can parse the finished record.
  [ -n "$out" ] || return 0
  CODEX_META_KNOWN_OF["$codex_file"]=1
  IFS=$'\t' read -r CODEX_CWD_OF["$codex_file"] \
    CODEX_ID_OF["$codex_file"] CODEX_SESSION_OF["$codex_file"] \
    CODEX_PARENT_OF["$codex_file"] CODEX_SUBAGENT_OF["$codex_file"] <<< "$out"
  [ "${CODEX_CWD_OF[$codex_file]}" = - ] && CODEX_CWD_OF["$codex_file"]=""
  [ "${CODEX_ID_OF[$codex_file]}" = - ] && CODEX_ID_OF["$codex_file"]=""
  [ "${CODEX_SESSION_OF[$codex_file]}" = - ] && CODEX_SESSION_OF["$codex_file"]=""
  [ "${CODEX_PARENT_OF[$codex_file]}" = - ] && CODEX_PARENT_OF["$codex_file"]=""
  return 0
}

codex_file_owned_by_pane_client() {
  local owner="${CODEX_OPEN_OWNER_OF[$1]:-}"
  [ -n "$owner" ] && [ -n "${PANE_CODEX_PID[$owner]:-}" ]
}

# Newer Codex clients can delegate every rollout handle to one shared app-server
# daemon. In that mode the pane-local pid has no direct lsof match. Match cwd and
# root session identity; if either identifies multiple unassigned clients or
# sessions, leave them unassigned rather than displaying another pane's status.
codex_shared_files_for_pid() {
  # codex_shared_files_for_pid <pid> <output-variable>
  local pid="$1" output_var="$2" cwd candidate root_id="" group="" other_pid
  local client_count=0 result="" cached="${CODEX_FILES_OF[$pid]:-}" other_cwd
  local -A groups=() seen=()
  codex_cached_cwd_for_pid "$pid" cwd
  if [ -z "$cwd" ] || [ -z "$CODEX_ALL_OPEN_FILES" ]; then
    printf -v "$output_var" ''
    return 1
  fi

  while IFS= read -r candidate; do
    [ -f "$candidate" ] || continue
    codex_file_owned_by_pane_client "$candidate" && continue
    codex_metadata_for_file "$candidate"
    [ "${CODEX_CWD_OF[$candidate]:-}" = "$cwd" ] || continue
    group="${CODEX_SESSION_OF[$candidate]:-}"
    [ -n "$group" ] || { [ "${CODEX_SUBAGENT_OF[$candidate]:-}" != 1 ] \
      && group="${CODEX_ID_OF[$candidate]:-}"; }
    [ -n "$group" ] && groups["$group"]=1
  done <<< "$CODEX_ALL_OPEN_FILES"

  if [ "${#groups[@]}" -eq 0 ]; then
    printf -v "$output_var" ''
    return 1
  fi
  [ "${#groups[@]}" -eq 1 ] || { printf -v "$output_var" ''; return 2; }
  for group in "${!groups[@]}"; do root_id="$group"; done
  # More than one pane-local Codex client in this cwd is ambiguous even if
  # the shared server currently has only one rollout group open.
  for other_pid in "${!PANE_CODEX_PID[@]}"; do
    [ -n "${CODEX_OPEN_FILES_OF[$other_pid]:-}" ] && continue
    codex_cached_cwd_for_pid "$other_pid" other_cwd
    [ "$other_cwd" = "$cwd" ] || continue
    client_count=$((client_count + 1))
    [ "$client_count" -le 1 ] || { printf -v "$output_var" ''; return 2; }
  done

  # Keep previously associated children when their handles close between
  # snapshots, as long as the file still belongs to this root session.
  while IFS= read -r candidate; do
    [ -n "$candidate" ] && [ -f "$candidate" ] || continue
    [ -z "${seen[$candidate]:-}" ] || continue
    codex_file_owned_by_pane_client "$candidate" && continue
    codex_metadata_for_file "$candidate"
    [ "${CODEX_SESSION_OF[$candidate]:-}" = "$root_id" ] \
      || [ "${CODEX_PARENT_OF[$candidate]:-}" = "$root_id" ] \
      || { [ "${CODEX_SUBAGENT_OF[$candidate]:-}" != 1 ] \
        && [ "${CODEX_ID_OF[$candidate]:-}" = "$root_id" ]; } || continue
    seen["$candidate"]=1
    result+="${result:+$'\n'}$candidate"
  done <<< "$CODEX_ALL_OPEN_FILES"$'\n'"$cached"
  printf -v "$output_var" '%s' "$result"
  [ -n "$result" ]
}

# Query all known rollout sizes with one stat process. A separate stat per file
# was more expensive than the actual cached status computation.
snapshot_codex_sizes() {
  CODEX_SIZE_SNAPSHOT_OF=()
  local -A seen=()
  local -a paths=()
  local files candidate line path size
  # Guarded expansion: Bash before 4.4 treats an empty array as unbound under
  # `set -u`, and both maps are empty whenever no Codex process is running.
  for files in "${CODEX_OPEN_FILES_OF[@]+"${CODEX_OPEN_FILES_OF[@]}"}" \
    "${CODEX_FILES_OF[@]+"${CODEX_FILES_OF[@]}"}"; do
    while IFS= read -r candidate; do
      [ -f "$candidate" ] || continue
      [ -z "${seen[$candidate]:-}" ] || continue
      seen["$candidate"]=1
      paths+=("$candidate")
    done <<< "$files"
  done
  [ "${#paths[@]}" -gt 0 ] || return

  if [ "$STAT_SIZE_STYLE" = bsd ]; then
    while IFS=$'\t' read -r path size; do
      CODEX_SIZE_SNAPSHOT_OF["$path"]="$size"
    done < <(stat -f $'%N\t%z' "${paths[@]}" 2>/dev/null)
  else
    while IFS=$'\t' read -r path size; do
      CODEX_SIZE_SNAPSHOT_OF["$path"]="$size"
    done < <(stat -c $'%n\t%s' "${paths[@]}" 2>/dev/null)
  fi
}

codex_files_for_pid() {
  # codex_files_for_pid <pid> <output-variable>
  local pid="$1" output_var="$2"
  local cached="${CODEX_FILES_OF[$pid]:-}" candidate
  local files="${CODEX_OPEN_FILES_OF[$pid]:-}" valid_cached="" shared_result=0

  # Use the consolidated per-poll snapshot so newly opened/resumed rollouts
  # join the aggregate without spawning lsof once per Codex process.
  while IFS= read -r candidate; do
    [ -f "$candidate" ] || continue
    CODEX_FILE_PID_OF["$candidate"]="$pid"
  done <<< "$files"

  if [ -n "$files" ]; then
    CODEX_FILES_OF["$pid"]="$files"
    printf -v "$output_var" '%s' "$files"
    return 0
  fi

  # Shared app-server fallback. Recompute this on every lsof snapshot so a new
  # or resumed root session in the same working directory replaces stale state.
  codex_shared_files_for_pid "$pid" files || shared_result=$?
  if [ -n "$files" ]; then
    CODEX_FILES_OF["$pid"]="$files"
    printf -v "$output_var" '%s' "$files"
    return 0
  fi
  if [ "$shared_result" -eq 2 ]; then
    unset 'CODEX_FILES_OF[$pid]'
    printf -v "$output_var" ''
    return 1
  fi

  # Codex may close rollout handles briefly between turns. Preserve all cached
  # paths that still exist until the process exits (reconcile clears the set).
  while IFS= read -r candidate; do
    [ -f "$candidate" ] || continue
    valid_cached+="${valid_cached:+$'\n'}$candidate"
  done <<< "$cached"
  if [ -n "$valid_cached" ]; then
    CODEX_FILES_OF["$pid"]="$valid_cached"
    printf -v "$output_var" '%s' "$valid_cached"
    return 0
  fi
  unset 'CODEX_FILES_OF[$pid]'
  printf -v "$output_var" ''
  return 1
}

# A rollout's status is derived from its last turn-boundary event:
#   task_started (no later task_complete) -> busy;  task_complete -> idle;
#   turn_aborted -> cleared. ts comes from the boundary event's ISO timestamp.
status_for_codex_file() {
  # status_for_codex_file <file> <status-variable> <timestamp-variable>
  local codex_file="$1" status_var="$2" timestamp_var="$3"
  local out ev tsms st="" seeded="${CODEX_KNOWN_OF[$codex_file]:-}"
  local size="${CODEX_SIZE_SNAPSHOT_OF[$codex_file]:-}"
  if [ -z "$size" ]; then
    if [ "$STAT_SIZE_STYLE" = bsd ]; then
      size="$(stat -f %z "$codex_file" 2>/dev/null)"
    else
      size="$(stat -c %s "$codex_file" 2>/dev/null)"
    fi
  fi
  case "$size" in ''|*[!0-9]*) size=0 ;; esac

  # Rollouts are append-only. If the byte size is unchanged, no boundary can
  # have changed, so avoid spawning tail+jq and return the cached state.
  if [ -n "$seeded" ] && [ "${CODEX_SIZE_OF[$codex_file]:--1}" = "$size" ]; then
    printf -v "$status_var" '%s' "${CODEX_STATUS_OF[$codex_file]:-}"
    printf -v "$timestamp_var" '%s' "${CODEX_TS_OF[$codex_file]:-0}"
    return
  fi

  # Seed a newly discovered rollout from its full history once. Later polls only
  # inspect a bounded tail; if a long running turn pushes task_started beyond
  # that tail, retain the cached boundary instead of incorrectly going blank.
  if [ -z "$seeded" ]; then
    out="$(jq -Rrn '
      ([ inputs
         | fromjson?
         | {t: (.payload.type // .type // ""), ts: (.timestamp // "")}
         | select(.t=="task_started" or .t=="task_complete" or .t=="turn_aborted") ]
       | last) as $e
      | if $e == null then empty
        else $e.t + "\t"
          + ((try (($e.ts | sub("\\.[0-9]+";"") | fromdateiso8601) * 1000) catch 0) | tostring)
        end' "$codex_file" 2>/dev/null)"
  else
    out="$(tail -n 400 "$codex_file" 2>/dev/null | jq -Rrn '
      ([ inputs
         | fromjson?
         | {t: (.payload.type // .type // ""), ts: (.timestamp // "")}
         | select(.t=="task_started" or .t=="task_complete" or .t=="turn_aborted") ]
       | last) as $e
      | if $e == null then empty
        else $e.t + "\t"
          + ((try (($e.ts | sub("\\.[0-9]+";"") | fromdateiso8601) * 1000) catch 0) | tostring)
        end' 2>/dev/null)"
  fi
  if [ -z "$out" ]; then
    CODEX_KNOWN_OF["$codex_file"]=1
    CODEX_SIZE_OF["$codex_file"]="$size"
    printf -v "$status_var" '%s' "${CODEX_STATUS_OF[$codex_file]:-}"
    printf -v "$timestamp_var" '%s' "${CODEX_TS_OF[$codex_file]:-0}"
    return
  fi
  ev="${out%%$'\t'*}"
  tsms="${out#*$'\t'}"
  case "$ev" in
    task_started)  st="busy" ;;
    task_complete) st="idle" ;;
    *)             st="" ;;
  esac
  case "$tsms" in ''|0|null) tsms="$(file_mtime "$codex_file")000"; [ "$tsms" = "000" ] && tsms=0 ;; esac
  CODEX_KNOWN_OF["$codex_file"]=1
  CODEX_STATUS_OF["$codex_file"]="$st"
  CODEX_TS_OF["$codex_file"]="$tsms"
  CODEX_SIZE_OF["$codex_file"]="$size"
  printf -v "$status_var" '%s' "$st"
  printf -v "$timestamp_var" '%s' "$tsms"
}

# Aggregate every rollout held by a codex pid. A working rollout wins over an
# idle one; timestamps break ties within the same state rank.
status_for_codex_pid() {
  # status_for_codex_pid <pid> <status-variable> <timestamp-variable>
  local pid="$1" status_var="$2" timestamp_var="$3"
  local codex_files="" codex_file file_st file_ts rank best=0
  local best_st="" best_ts=0
  if ! codex_files_for_pid "$pid" codex_files; then
    printf -v "$status_var" ''
    printf -v "$timestamp_var" '0'
    return
  fi

  while IFS= read -r codex_file; do
    [ -n "$codex_file" ] || continue
    file_st=""; file_ts=0
    status_for_codex_file "$codex_file" file_st file_ts
    case "$file_st" in
      busy|shell) rank=3 ;;
      idle)       rank=1 ;;
      *)          rank=0 ;;
    esac
    if [ "$rank" -gt "$best" ] \
      || { [ "$rank" -eq "$best" ] && [ "${file_ts:-0}" -gt "${best_ts:-0}" ] 2>/dev/null; }; then
      best="$rank"; best_st="$file_st"; best_ts="${file_ts:-0}"
    fi
  done <<< "$codex_files"

  printf -v "$status_var" '%s' "$best_st"
  printf -v "$timestamp_var" '%s' "$best_ts"
}

base_icon_for_status() {
  # base_icon_for_status <status> <viewing> <seen-ts> <status-ts> <output-var>
  local status="$1" viewing="$2" seen="$3" status_ts="$4" output_var="$5"
  local result_icon=""
  case "$status" in
    busy|shell) result_icon="$ICON_WORKING" ;;
    waiting)    result_icon="$ICON_WAITING" ;;
    idle)
      if [ "$viewing" != "1" ] && [ "$seen" -lt "$status_ts" ] 2>/dev/null; then
        result_icon="$ICON_DONE"
      fi
      ;;
  esac
  printf -v "$output_var" '%s' "$result_icon"
}

result_is_visible() {
  # result_is_visible <window-active> <popup-count> <output-variable>
  local window_active="$1" popup_count="$2" output_var="$3" result=0
  case "$popup_count" in ''|*[!0-9]*) popup_count=0 ;; esac
  [ "$window_active" = 1 ] && [ "$popup_count" -eq 0 ] && result=1
  printf -v "$output_var" '%s' "$result"
}

set_window_status() {
  # set_window_status <window-id> <current> <desired>
  local window="$1" current="$2" desired="$3"
  [ "$current" = "$desired" ] && return 0
  if [ -z "$desired" ]; then
    tm set-option -w -u -t "$window" "$STATUS_VAR" >/dev/null 2>&1 || true
  else
    tm set-option -w -t "$window" "$STATUS_VAR" "$desired" >/dev/null 2>&1 || true
  fi
}

set_session_summary() {
  # set_session_summary <session-id> <current> <desired>
  local session="$1" current="$2" desired="$3"
  [ "$current" = "$desired" ] && return 0
  if [ -z "$desired" ]; then
    tm set-option -u -t "$session" "$SUMMARY_VAR" >/dev/null 2>&1 || true
  else
    tm set-option -t "$session" "$SUMMARY_VAR" "$desired" >/dev/null 2>&1 || true
  fi
}

reconcile() {
  local pane_snapshot pane_format pane_fingerprint=""
  local fp_pane fp_window fp_session fp_index fp_pid fp_pane_active fp_window_active
  local fp_current fp_ts fp_seen fp_popup fp_summary fp_command
  local poll_now_us process_refreshed=0
  if [ -n "${EPOCHREALTIME:-}" ]; then
    poll_now_us="${EPOCHREALTIME/./}"
  else
    poll_now_us=$(( $(date +%s) * 1000000 ))
  fi

  pane_format="#{pane_id}"$'\t'"#{window_id}"$'\t'"#{session_id}"$'\t'"#{window_index}"$'\t'"#{pane_pid}"$'\t'"#{pane_active}"$'\t'"#{window_active}"$'\t'"#{?$STATUS_VAR,#{$STATUS_VAR},-}"$'\t'"#{?@agent_status_ts,#{@agent_status_ts},0}"$'\t'"#{?@agent_status_seen,#{@agent_status_seen},0}"$'\t'"#{?@agent_status_popup_count,#{@agent_status_popup_count},0}"$'\t'"#{?$SUMMARY_VAR,#{$SUMMARY_VAR},-}"$'\t'"#{pane_current_command}"
  pane_snapshot="$(tm list-panes -a -F "$pane_format" 2>/dev/null)"
  while IFS=$'\t' read -r fp_pane fp_window fp_session fp_index fp_pid \
    fp_pane_active fp_window_active fp_current fp_ts fp_seen fp_popup \
    fp_summary fp_command; do
    [ -n "${fp_pane:-}" ] || continue
    pane_fingerprint+="${pane_fingerprint:+$'\n'}$fp_pane"$'\t'"$fp_pid"$'\t'"$fp_command"
  done <<< "$pane_snapshot"

  # Foreground command or pane changes refresh the process tree immediately.
  # A slow watchdog covers nested launchers whose foreground name stays fixed.
  if [ "$pane_fingerprint" != "$PANE_PROCESS_FINGERPRINT" ] \
    || [ $(( 10#$poll_now_us - PROCESS_SNAPSHOT_AT_US )) -ge "$PROCESS_SNAPSHOT_TTL_US" ]; then
    snapshot_processes
    PROCESS_SNAPSHOT_AT_US=$(( 10#$poll_now_us ))
    PANE_PROCESS_FINGERPRINT="$pane_fingerprint"
    process_refreshed=1
    snapshot_pane_codex_pids "$pane_snapshot"
    CODEX_CWD_OF_PID=()
  fi

  # Known rollout contents are still checked every poll. Handle discovery is
  # refreshed on process changes and every two seconds for resumed rollouts.
  if [ "$process_refreshed" = 1 ] \
    || [ $(( 10#$poll_now_us - CODEX_SNAPSHOT_AT_US )) -ge "$CODEX_SNAPSHOT_TTL_US" ]; then
    snapshot_codex_files
    CODEX_SNAPSHOT_AT_US=$(( 10#$poll_now_us ))
  fi
  snapshot_codex_sizes

  # Drop cached agent state after its process exits.
  local _p _f
  for _p in "${!CLAUDE_FILE_OF[@]}"; do
    if [ -z "${PPID_OF[$_p]:-}" ]; then
      _f="${CLAUDE_FILE_OF[$_p]}"
      unset 'CLAUDE_FILE_OF[$_p]' 'CLAUDE_CONTENT_OF[$_f]' \
        'CLAUDE_STATUS_OF[$_f]' 'CLAUDE_TS_OF[$_f]'
    fi
  done
  for _p in "${!CODEX_FILES_OF[@]}"; do
    [ -n "${PPID_OF[$_p]:-}" ] || unset 'CODEX_FILES_OF[$_p]'
  done
  for _f in "${!CODEX_FILE_PID_OF[@]}"; do
    _p="${CODEX_FILE_PID_OF[$_f]}"
    if [ -z "${PPID_OF[$_p]:-}" ]; then
      unset 'CODEX_FILE_PID_OF[$_f]' 'CODEX_KNOWN_OF[$_f]' \
        'CODEX_STATUS_OF[$_f]' 'CODEX_TS_OF[$_f]' 'CODEX_SIZE_OF[$_f]'
    fi
  done

  local now_ms thr_ms
  if [ -n "${EPOCHSECONDS:-}" ]; then
    now_ms=$(( EPOCHSECONDS * 1000 ))
  else
    now_ms=$(( $(date +%s) * 1000 ))
  fi
  thr_ms=$(( RECENT_DAYS * 86400 * 1000 ))

  local pane window session window_index pane_pid pane_active win_active current current_ts current_seen popup_count current_summary pane_command
  local st ts base viewing final seen
  local apid akind ast ats rank current_rank agent_pids
  local -A WINDOW_KNOWN=() WINDOW_CURRENT=() WINDOW_CURRENT_TS=()
  local -A WINDOW_SEEN=() WINDOW_ACTIVE=() WINDOW_POPUP=()
  local -A WINDOW_STATUS=() WINDOW_TS=() WINDOW_RANK=() WINDOW_FINAL=()
  local -A SESSION_KNOWN=() SESSION_CURRENT=() SESSION_WINDOWS=()
  local -A SESSION_WINDOW_KNOWN=() SESSION_WINDOW_INDEX=()

  # First reduce every agent from every pane into one state per window. The
  # status option is window-scoped, so writing once per pane makes an empty pane
  # fight an agent pane using the same stale snapshot and causes icon flicker.
  while IFS=$'\t' read -r pane window session window_index pane_pid pane_active \
    win_active current current_ts current_seen popup_count current_summary \
    pane_command; do
    [ -z "${pane:-}" ] && continue
    [ "$current" = "-" ] && current=""
    [ "$current_summary" = "-" ] && current_summary=""
    if [ -z "${SESSION_KNOWN[$session]:-}" ]; then
      SESSION_KNOWN["$session"]=1
      SESSION_CURRENT["$session"]="$current_summary"
      SESSION_WINDOWS["$session"]=""
    fi
    if [ -z "${SESSION_WINDOW_KNOWN[$session:$window]:-}" ]; then
      SESSION_WINDOW_KNOWN["$session:$window"]=1
      SESSION_WINDOW_INDEX["$session:$window"]="$window_index"
      SESSION_WINDOWS["$session"]+="${SESSION_WINDOWS[$session]:+ }$window"
    fi
    if [ -z "${WINDOW_KNOWN[$window]:-}" ]; then
      WINDOW_KNOWN["$window"]=1
      WINDOW_CURRENT["$window"]="$current"
      WINDOW_CURRENT_TS["$window"]="${current_ts:-0}"
      WINDOW_SEEN["$window"]="${current_seen:-0}"
      WINDOW_ACTIVE["$window"]="$win_active"
      WINDOW_POPUP["$window"]="${popup_count:-0}"
      WINDOW_STATUS["$window"]=""
      WINDOW_TS["$window"]=0
      WINDOW_RANK["$window"]=0
    fi
    # A linked window may appear through more than one session. Treat it as
    # visible if any occurrence is active rather than trusting list order.
    [ "$win_active" = 1 ] && WINDOW_ACTIVE["$window"]=1

    agent_pids=""
    find_agent_pids "$pane_pid" agent_pids || true
    while IFS=$'\t' read -r apid akind; do
      [ -z "${apid:-}" ] && continue
      if [ "$akind" = "codex" ]; then
        # Call directly (not through process substitution) so a refreshed
        # pid->rollout cache remains in this shell for later polls.
        ast=""; ats=0
        status_for_codex_pid "$apid" ast ats
      else
        ast=""; ats=0
        status_for_pid "$apid" ast ats
      fi
      case "$ast" in
        busy|shell) rank=3 ;;
        waiting)    rank=2 ;;
        idle)       rank=1 ;;
        *)          rank=0 ;;
      esac
      current_rank="${WINDOW_RANK[$window]:-0}"
      if [ "$rank" -gt "$current_rank" ] \
        || { [ "$rank" -eq "$current_rank" ] \
          && [ "${ats:-0}" -gt "${WINDOW_TS[$window]:-0}" ] 2>/dev/null; }; then
        WINDOW_RANK["$window"]="$rank"
        WINDOW_STATUS["$window"]="$ast"
        WINDOW_TS["$window"]="${ats:-0}"
      fi
    done <<< "$agent_pids"
  done <<< "$pane_snapshot"

  # Apply sticky-done and publish status exactly once for each window.
  for window in "${!WINDOW_KNOWN[@]}"; do
    current="${WINDOW_CURRENT[$window]}"
    current_ts="${WINDOW_CURRENT_TS[$window]:-0}"
    current_seen="${WINDOW_SEEN[$window]:-0}"
    st="${WINDOW_STATUS[$window]:-}"
    ts="${WINDOW_TS[$window]:-0}"
    base=""
    result_is_visible "${WINDOW_ACTIVE[$window]}" \
      "${WINDOW_POPUP[$window]:-0}" viewing
    seen=0
    if [ "$st" = "idle" ]; then
      # Sticky done: cleared once the window has been viewed at/after this
      # completion, and stays cleared until a NEW completion. Only done uses
      # the seen marker; working and waiting remain visible while viewed.
      seen="${current_seen:-0}"
      if [ "$viewing" = "1" ] && [ "$seen" -lt "$ts" ] 2>/dev/null; then
        tm set-option -w -t "$window" @agent_status_seen "$ts" >/dev/null 2>&1 || true
        seen="$ts"
      fi
    fi
    base_icon_for_status "$st" "$viewing" "$seen" "$ts" base

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
    WINDOW_FINAL["$window"]="$final"
    set_window_status "$window" "$current" "$final"
    # Publish the status timestamp (statusUpdatedAt = finish time when done,
    # trigger time when working) so consumers can sort by it. Keep it after a
    # done icon is seen: icon visibility and the latest agent boundary are
    # separate state, and consumers must not fall back to churning pane output.
    if [ -n "$st" ] && [ "$ts" -gt 0 ] 2>/dev/null; then
      [ "${current_ts:-0}" = "$ts" ] \
        || tm set-option -w -t "$window" @agent_status_ts "$ts" >/dev/null 2>&1 || true
    else
      [ "${current_ts:-0}" = "0" ] \
        || tm set-option -w -u -t "$window" @agent_status_ts >/dev/null 2>&1 || true
    fi
  done

  # Build one compact section per session in tmux's window order. list-panes -a
  # is grouped by session and window index, while the seen map ensures a
  # multi-pane window contributes only one entry.
  local summary entry
  for session in "${!SESSION_KNOWN[@]}"; do
    summary=""
    for window in ${SESSION_WINDOWS[$session]:-}; do
      final="${WINDOW_FINAL[$window]:-}"
      [ -n "$final" ] || continue
      entry="${SESSION_WINDOW_INDEX[$session:$window]}:$final"
      summary+="${summary:+ }$entry"
    done
    set_session_summary "$session" "${SESSION_CURRENT[$session]:-}" "$summary"
  done
}

# Clean up only our own recorded PID on exit. An older daemon may finish after a
# replacement has already published its PID; unconditionally unsetting the
# option here would orphan the replacement and allow another duplicate launch.
clear_recorded_pid() {
  [ "$(tm show-option -gqv @agent_status_pid 2>/dev/null)" = "$$" ] \
    && tm set-option -gu @agent_status_pid >/dev/null 2>&1 || true
}

wait_for_next_poll() {
  local cycle_started="$1"
  if [ -n "$cycle_started" ]; then
    local cycle_finished="$EPOCHREALTIME" started_us finished_us remaining_us
    local remaining_sleep
    started_us="${cycle_started/./}"
    finished_us="${cycle_finished/./}"
    remaining_us=$(( INTERVAL_US - (10#$finished_us - 10#$started_us) ))
    if [ "$remaining_us" -gt 0 ]; then
      printf -v remaining_sleep '%d.%06d' \
        "$(( remaining_us / 1000000 ))" "$(( remaining_us % 1000000 ))"
      sleep "$remaining_sleep"
    fi
  else
    sleep "$INTERVAL"
  fi
}

# One-shot mode: reconcile once and exit (for testing / manual refresh).
if [ -n "${AGENT_STATUS_SOURCE_ONLY:-}" ]; then
  return 0 2>/dev/null || exit 0
elif [ -n "${AGENT_STATUS_ONESHOT:-}" ]; then
  reconcile
  exit 0
fi

trap clear_recorded_pid EXIT

while true; do
  server_alive || exit 0
  cycle_started="${EPOCHREALTIME:-}"
  reconcile
  wait_for_next_poll "$cycle_started"
done
