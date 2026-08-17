#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-status-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

export AGENT_STATUS_SOURCE_ONLY=1
unset AGENT_STATUS_INTERVAL
# shellcheck source=../scripts/poller.sh
source "$ROOT_DIR/scripts/poller.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local want="$1" got="$2" message="$3"
  [ "$want" = "$got" ] || fail "$message (want=$want got=$got)"
}

assert_eq 0.5 "$INTERVAL" 'default polling cadence should be half a second'
assert_eq 500000 "$INTERVAL_US" 'default polling cadence should be half a million microseconds'

SESSION_DIR="$TEST_DIR/sessions/2026/01/01"
mkdir -p "$SESSION_DIR"
OLD_ROLLOUT="$SESSION_DIR/rollout-2026-01-01T01-00-00-old.jsonl"
NEW_ROLLOUT="$SESSION_DIR/rollout-2026-01-01T02-00-00-new.jsonl"
LONG_ROLLOUT="$SESSION_DIR/rollout-2026-01-01T03-00-00-long.jsonl"
PARTIAL_ROLLOUT="$SESSION_DIR/rollout-2026-01-01T04-00-00-partial.jsonl"

printf '%s\n' \
  '{"timestamp":"2026-01-01T01:00:00.000Z","type":"event_msg","payload":{"type":"task_complete"}}' \
  >"$OLD_ROLLOUT"
printf '%s\n' \
  '{"timestamp":"2026-01-01T02:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}' \
  >"$NEW_ROLLOUT"

OPEN_ROLLOUTS="$OLD_ROLLOUT"

# One lsof snapshot should map rollout handles for every Codex process.
lsof() {
  printf 'p42\nfcwd\nn%s\nn/tmp/not-a-rollout\np43\nn%s\n' \
    "$OLD_ROLLOUT" "$NEW_ROLLOUT"
}
HAS_CODEX_PROCESS=1
snapshot_codex_files
assert_eq "$OLD_ROLLOUT" "${CODEX_OPEN_FILES_OF[42]:-}" 'lsof snapshot should map the first Codex rollout'
assert_eq "$NEW_ROLLOUT" "${CODEX_OPEN_FILES_OF[43]:-}" 'lsof snapshot should map the second Codex rollout'
unset -f lsof

status_for_test_pid() {
  CODEX_OPEN_FILES_OF["$1"]="$OPEN_ROLLOUTS"
  status_for_codex_pid "$@"
}

status=""; timestamp=0
status_for_test_pid 42 status timestamp
assert_eq idle "$status" 'initial completed rollout should be idle'
assert_eq "$OLD_ROLLOUT" "${CODEX_FILES_OF[42]:-}" 'initial rollout should be cached'

# A resumed session leaves the old file open and adds a newer one. The detector
# must aggregate both instead of continuing to parse lsof's first match.
OPEN_ROLLOUTS="$OLD_ROLLOUT"$'\n'"$NEW_ROLLOUT"
status_for_test_pid 42 status timestamp
assert_eq busy "$status" 'new task_started event should show the working marker'
assert_eq "$OPEN_ROLLOUTS" "${CODEX_FILES_OF[42]:-}" 'all open rollouts should be cached'

# A more recently completed rollout must not hide another rollout that is still
# working in the same Codex process.
printf '%s\n' \
  '{"timestamp":"2026-01-01T01:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}' \
  >"$OLD_ROLLOUT"
printf '%s\n' \
  '{"timestamp":"2026-01-01T02:05:00.000Z","type":"event_msg","payload":{"type":"task_complete"}}' \
  >"$NEW_ROLLOUT"
status_for_test_pid 42 status timestamp
assert_eq busy "$status" 'working rollout should outrank a newer completed rollout'

# If Codex briefly closes its log handles, the aggregate cache must survive.
OPEN_ROLLOUTS=""
status_for_test_pid 42 status timestamp
assert_eq busy "$status" 'cached rollouts should survive closed handles'

printf '%s\n' \
  '{"timestamp":"2026-01-01T01:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}' \
  '{"timestamp":"2026-01-01T03:00:00.000Z","type":"event_msg","payload":{"type":"task_complete"}}' \
  >"$OLD_ROLLOUT"
status_for_test_pid 42 status timestamp
assert_eq idle "$status" 'all completed rollouts should show the done marker'

icon=""
base_icon_for_status busy 1 0 100 icon
assert_eq "$ICON_WORKING" "$icon" 'viewing must not clear working'
base_icon_for_status waiting 1 0 100 icon
assert_eq "$ICON_WAITING" "$icon" 'viewing must not clear waiting'
base_icon_for_status idle 1 0 100 icon
assert_eq '' "$icon" 'viewing should clear done'
base_icon_for_status idle 0 99 100 icon
assert_eq "$ICON_DONE" "$icon" 'unseen completion should show done'
base_icon_for_status idle 0 100 100 icon
assert_eq '' "$icon" 'seen completion should keep done cleared'

viewing=0
result_is_visible 1 0 viewing
assert_eq 1 "$viewing" 'active window without popup should expose the result'
result_is_visible 1 1 viewing
assert_eq 0 "$viewing" 'popup should keep an active window result unseen'
result_is_visible 0 0 viewing
assert_eq 0 "$viewing" 'inactive window should keep the result unseen'

# A newly discovered long-running rollout may already have pushed task_started
# beyond the bounded polling tail. Its one-time full scan must still seed busy.
printf '%s\n' \
  '{"timestamp":"2026-01-01T04:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}' \
  >"$LONG_ROLLOUT"
for fixture_index in {1..500}; do
  printf '%s\n' '{"timestamp":"2026-01-01T04:00:01.000Z","type":"event_msg","payload":{"type":"token_count"}}' \
    >>"$LONG_ROLLOUT"
done
OPEN_ROLLOUTS="$LONG_ROLLOUT"
status_for_test_pid 43 status timestamp
assert_eq busy "$status" 'full seed should find task_started outside the polling tail'

# Once seeded, the same long turn must retain busy when no boundary is present
# in later bounded-tail scans.
status_for_test_pid 43 status timestamp
assert_eq busy "$status" 'cached boundary should keep a long turn working'

printf '%s\n' \
  '{"timestamp":"2026-01-01T04:10:00.000Z","type":"event_msg","payload":{"type":"task_complete"}}' \
  >>"$LONG_ROLLOUT"
status_for_test_pid 43 status timestamp
assert_eq idle "$status" 'new completion should replace the cached working boundary'

# A writer may be observed between JSONL writes or leave a malformed line after
# interruption. Invalid lines must not make jq discard valid boundaries around
# them or cache an outdated status forever.
printf '%s\n' \
  '{"timestamp":"2026-01-01T05:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}' \
  '{"timestamp":' \
  >"$PARTIAL_ROLLOUT"
OPEN_ROLLOUTS="$PARTIAL_ROLLOUT"
status_for_test_pid 44 status timestamp
assert_eq busy "$status" 'full seed should ignore a malformed trailing JSONL line'
printf '%s\n' \
  '{"timestamp":"2026-01-01T05:10:00.000Z","type":"event_msg","payload":{"type":"task_complete"}}' \
  >>"$PARTIAL_ROLLOUT"
status_for_test_pid 44 status timestamp
assert_eq idle "$status" 'tail refresh should parse a completion after a malformed line'

# Process discovery should use the prebuilt parent->children index and stop at
# the agent process instead of descending into its own subprocesses.
PPID_OF=([101]=100 [102]=101 [103]=102)
COMM_OF=([100]=zsh [101]=nvim [102]=codex [103]=helper)
CHILDREN_OF=([100]=101 [101]=102 [102]=103)
agent_match=""
find_agent_pids 100 agent_match
assert_eq $'102\tcodex' "$agent_match" 'indexed process walk should find the Codex descendant'

# Claude status files are tiny snapshots. Re-reading exact content avoids
# timestamp-resolution races while the parsed state remains cached unchanged.
CLAUDE_DIR="$TEST_DIR/claude"
mkdir -p "$CLAUDE_DIR/sessions"
CONFIG_DIRS="$CLAUDE_DIR"
printf '%s\n' '{"status":"busy","statusUpdatedAt":100}' >"$CLAUDE_DIR/sessions/77.json"
status=""; timestamp=0
status_for_pid 77 status timestamp
assert_eq busy "$status" 'Claude busy status should be parsed'
assert_eq 100 "$timestamp" 'Claude status timestamp should be parsed'
status_for_pid 77 status timestamp
assert_eq busy "$status" 'unchanged Claude content should retain cached status'
printf '%s\n' '{"status":"idle","statusUpdatedAt":200}' >"$CLAUDE_DIR/sessions/77.json"
status_for_pid 77 status timestamp
assert_eq idle "$status" 'changed Claude content should refresh cached status'
assert_eq 200 "$timestamp" 'changed Claude timestamp should refresh cache'

# @agent_status is window-scoped. A window with one Codex pane and one empty
# pane must publish exactly once; otherwise the two panes alternately set and
# clear the same option using a stale per-window snapshot.
STATUS_WRITES=0
STATUS_VALUE=""
TIMESTAMP_WRITES=0
TIMESTAMP_VALUE=0
MOCK_CURRENT="-"
MOCK_TIMESTAMP=0
MOCK_AGENT_STATE=busy
MOCK_AGENT_TIMESTAMP=100
tm() {
  if [ "${1:-}" = list-panes ]; then
    printf '%%1\t@1\t100\t1\t1\t%s\t%s\t0\t0\tcodex\n' "$MOCK_CURRENT" "$MOCK_TIMESTAMP"
    printf '%%2\t@1\t200\t0\t1\t%s\t%s\t0\t0\tzsh\n' "$MOCK_CURRENT" "$MOCK_TIMESTAMP"
    return
  fi
  if [ "${1:-}" = set-option ]; then
    local arg is_status=0 is_timestamp=0 is_unset=0
    for arg in "$@"; do [ "$arg" = "$STATUS_VAR" ] && is_status=1; done
    for arg in "$@"; do [ "$arg" = @agent_status_ts ] && is_timestamp=1; done
    for arg in "$@"; do [ "$arg" = -u ] && is_unset=1; done
    if [ "$is_status" = 1 ]; then
      STATUS_WRITES=$((STATUS_WRITES + 1))
      if [ "$is_unset" = 1 ]; then STATUS_VALUE=""; else STATUS_VALUE="${*: -1}"; fi
      if [ -n "$STATUS_VALUE" ]; then MOCK_CURRENT="$STATUS_VALUE"; else MOCK_CURRENT="-"; fi
    fi
    if [ "$is_timestamp" = 1 ]; then
      TIMESTAMP_WRITES=$((TIMESTAMP_WRITES + 1))
      if [ "$is_unset" = 1 ]; then TIMESTAMP_VALUE=0; else TIMESTAMP_VALUE="${*: -1}"; fi
      MOCK_TIMESTAMP="$TIMESTAMP_VALUE"
    fi
  fi
}
snapshot_processes() {
  PPID_OF=([100]=1 [200]=1)
  COMM_OF=([100]=codex [200]=zsh)
  CHILDREN_OF=([1]='100 200')
  HAS_CODEX_PROCESS=1
}
snapshot_codex_files() { CODEX_OPEN_FILES_OF=(); }
snapshot_codex_sizes() { CODEX_SIZE_SNAPSHOT_OF=(); }
status_for_codex_pid() {
  printf -v "$2" '%s' "$MOCK_AGENT_STATE"
  printf -v "$3" '%s' "$MOCK_AGENT_TIMESTAMP"
}
PROCESS_SNAPSHOT_AT_US=0
CODEX_SNAPSHOT_AT_US=0
PANE_PROCESS_FINGERPRINT=""
reconcile
assert_eq 1 "$STATUS_WRITES" 'multi-pane window should receive one status write'
assert_eq "$ICON_WORKING" "$STATUS_VALUE" 'agent pane should keep the window working'
assert_eq 1 "$TIMESTAMP_WRITES" 'working status should publish its timestamp once'
assert_eq 100 "$TIMESTAMP_VALUE" 'working timestamp should match the agent boundary'
reconcile
assert_eq 1 "$STATUS_WRITES" 'empty sibling pane must not clear or rewrite the icon'
assert_eq 1 "$TIMESTAMP_WRITES" 'unchanged agent timestamp should not be rewritten'

# Seeing a completion clears only the done icon. The boundary timestamp remains
# available to consumers such as workspace-tree instead of falling back to pane
# output activity, and remains stable on later polls.
MOCK_AGENT_STATE=idle
MOCK_AGENT_TIMESTAMP=200
reconcile
assert_eq '' "$STATUS_VALUE" 'viewing a completion should clear its done icon'
assert_eq 2 "$TIMESTAMP_WRITES" 'seen completion should publish its timestamp'
assert_eq 200 "$TIMESTAMP_VALUE" 'completion timestamp should remain available after being seen'
reconcile
assert_eq 2 "$TIMESTAMP_WRITES" 'seen completion timestamp should remain stable'

printf 'ok - Codex rollout aggregation and viewed-status behavior\n'
