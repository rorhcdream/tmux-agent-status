#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-status-claude.XXXXXX")"
sleep 60 & WORKER=$!
sleep 60 & OTHER_WORKER=$!
trap 'kill "$WORKER" "$OTHER_WORKER" 2>/dev/null || true; wait 2>/dev/null || true; rm -rf "$TEST_DIR"' EXIT
export AGENT_STATUS_SOURCE_ONLY=1
source "$ROOT_DIR/scripts/poller.sh"

assert_eq() {
  [ "$1" = "$2" ] || { printf 'not ok - %s (want=%s got=%s)\n' "$3" "$1" "$2" >&2; exit 1; }
}

CONFIG_DIRS="$TEST_DIR/primary $TEST_DIR/other"
mkdir -p "$TEST_DIR/primary/sessions" "$TEST_DIR/other/sessions"
WORKER_FILE="$TEST_DIR/other/sessions/$WORKER.json"
OTHER_FILE="$TEST_DIR/primary/sessions/$OTHER_WORKER.json"
CLIENT_ARGS='/usr/local/bin/claude attach demo-job-1'
ps() {
  printf '100 1 zsh zsh\n101 100 claude %s\n' "$CLIENT_ARGS"
}
snapshot_processes
assert_eq demo-job-1 "${CLAUDE_JOB_OF_PID[101]:-}" 'snapshot should extract the attach job from an absolute executable path'
agent_match=""
find_agent_pids 100 agent_match
assert_eq $'101\tclaude' "$agent_match" 'attach client should be discovered below the pane'

check_status() {
  local want="$1" want_ts="$2" message="$3"
  status=""; timestamp=0
  CLAUDE_JOBS_SCANNED=0
  status_for_pid 101 status timestamp
  assert_eq "$want" "$status" "$message"
  assert_eq "$want_ts" "$timestamp" "$message timestamp"
}

check_status '' 0 'attach should stay blank until its worker record exists'
printf '{"pid":%s,"jobId":"demo-job-1","status":"busy","statusUpdatedAt":100}\n' "$WORKER" >"$WORKER_FILE"
check_status busy 100 'attach should use matching worker in another config directory'
printf '{"pid":%s,"jobId":"demo-job-1","status":"waiting","statusUpdatedAt":200}\n' "$WORKER" >"$WORKER_FILE"
check_status waiting 200 'worker transitions should refresh the parsed status'
printf '{"pid":%s,"jobId":"demo-job-1","status":"idle","statusUpdatedAt":300}\n' "$WORKER" >"$WORKER_FILE"
check_status idle 300 'idle should preserve the worker completion timestamp'

# A stale direct client-pid file must not hide the daemon association.
printf '{"status":"busy","statusUpdatedAt":999}\n' >"$TEST_DIR/primary/sessions/101.json"
CLAUDE_FILE_OF[101]="$TEST_DIR/primary/sessions/101.json"
check_status idle 300 'attach identity should take precedence over a stale direct pid file'

printf '{"pid":%s,"jobId":"other-job","status":"busy","statusUpdatedAt":400}\n' "$WORKER" >"$WORKER_FILE"
check_status '' 0 'changed worker job identity should invalidate the association'
printf '{"pid":%s,"jobId":"demo-job-1","procStart":"0","status":"busy","statusUpdatedAt":400}\n' "$WORKER" >"$WORKER_FILE"
if [ -r "/proc/$WORKER/stat" ]; then
  check_status '' 0 'reused worker pid should reject a stale process start token'
  proc_stat="$(< "/proc/$WORKER/stat")"
  read -r -a fields <<< "${proc_stat##*) }"
  printf '{"pid":%s,"jobId":"demo-job-1","procStart":"%s","status":"busy","statusUpdatedAt":400}\n' "$WORKER" "${fields[19]}" >"$WORKER_FILE"
  check_status busy 400 'matching process start token should accept a live worker'
fi
printf '{"pid":%s,"jobId":"demo-job-1","status":"busy","statusUpdatedAt":400}\n' "$WORKER" >"$WORKER_FILE"
printf '{"pid":%s,"jobId":"demo-job-1","status":"idle","statusUpdatedAt":500}\n' "$OTHER_WORKER" >"$OTHER_FILE"
check_status '' 0 'multiple live workers with the same job id should remain unassigned'
printf '{"pid":%s,"jobId":"unrelated","status":"idle","statusUpdatedAt":500}\n' "$OTHER_WORKER" >"$OTHER_FILE"
check_status busy 400 'unrelated worker should not affect the mapping'

kill "$WORKER"
wait "$WORKER" 2>/dev/null || true
check_status '' 0 'dead worker should clear status even if its file remains'
printf '{"pid":%s,"jobId":"demo-job-1","status":"shell","statusUpdatedAt":600}\n' "$OTHER_WORKER" >"$OTHER_FILE"
check_status shell 600 'replacement live worker should supersede the dead worker record'
printf '{"pid":' >"$OTHER_FILE"
check_status '' 0 'partial worker JSON should not reuse a cached status'
printf '{"pid":%s,"jobId":"demo-job-1","status":"idle","statusUpdatedAt":700}\n' "$OTHER_WORKER" >"$OTHER_FILE"
check_status idle 700 'completed JSON should be retried on the next poll'

# Exercise the actual poll boundary and window publication, including clearing
# a previously selected worker when its status file disappears.
MOCK_CURRENT=-
MOCK_TIMESTAMP=0
tm() {
  if [ "$1" = list-panes ]; then
    printf '%%1\t@1\t$1\t4\t100\t1\t0\t%s\t%s\t0\t0\t-\tclaude\n' "$MOCK_CURRENT" "$MOCK_TIMESTAMP"
  elif [ "$1" = set-option ] && [ "${5:-}" = "$STATUS_VAR" ]; then
    MOCK_CURRENT="${6:--}"
  elif [ "$1" = set-option ] && [ "${5:-}" = @agent_status_ts ]; then
    MOCK_TIMESTAMP="${6:-0}"
  elif [ "$1" = set-option ] && [ "${6:-}" = "$STATUS_VAR" ]; then
    MOCK_CURRENT=-
  elif [ "$1" = set-option ] && [ "${6:-}" = @agent_status_ts ]; then
    MOCK_TIMESTAMP=0
  fi
  return 0
}
snapshot_codex_files() { :; }
snapshot_codex_sizes() { :; }
reconcile
assert_eq "$ICON_DONE" "$MOCK_CURRENT" 'attach completion should publish the done icon'
assert_eq 700 "$MOCK_TIMESTAMP" 'attach completion should publish the worker timestamp'
printf '{"pid":%s,"jobId":"demo-job-1","status":"busy","statusUpdatedAt":800}\n' "$OTHER_WORKER" >"$OTHER_FILE"
reconcile
assert_eq "$ICON_WORKING" "$MOCK_CURRENT" 'next poll should refresh the worker index and publish working'
assert_eq 800 "$MOCK_TIMESTAMP" 'next poll should publish the new worker timestamp'
rm "$OTHER_FILE"
reconcile
assert_eq - "$MOCK_CURRENT" 'missing worker should clear the window icon'
assert_eq 0 "$MOCK_TIMESTAMP" 'missing worker should clear the window timestamp'
check_status '' 0 'deleted worker record should clear the association'

CLIENT_ARGS='claude attach another-job'
snapshot_processes
assert_eq another-job "${CLAUDE_JOB_OF_PID[101]:-}" 'process refresh should replace the attached job'
CLIENT_ARGS='claude --continue'
snapshot_processes
assert_eq '' "${CLAUDE_JOB_OF_PID[101]:-}" 'normal Claude should clear the old attach identity'
status_for_pid 101 status timestamp
assert_eq busy "$status" 'normal Claude should retain direct pid status support'
CLIENT_ARGS='claude attach'
snapshot_processes
assert_eq '' "${CLAUDE_JOB_OF_PID[101]:-}" 'missing job id should not create an association'
unset -f ps

printf 'ok - Claude daemon attach status and lifecycle\n'
