#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-status-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

export AGENT_STATUS_SOURCE_ONLY=1
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

SESSION_DIR="$TEST_DIR/sessions/2026/01/01"
mkdir -p "$SESSION_DIR"
OLD_ROLLOUT="$SESSION_DIR/rollout-2026-01-01T01-00-00-old.jsonl"
NEW_ROLLOUT="$SESSION_DIR/rollout-2026-01-01T02-00-00-new.jsonl"

printf '%s\n' \
  '{"timestamp":"2026-01-01T01:00:00.000Z","type":"event_msg","payload":{"type":"task_complete"}}' \
  >"$OLD_ROLLOUT"
printf '%s\n' \
  '{"timestamp":"2026-01-01T02:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}' \
  >"$NEW_ROLLOUT"

# Use identical second-resolution mtimes to exercise the rollout filename
# tiebreaker used on platforms whose stat(1) does not expose subsecond mtimes.
touch -t 202601010300 "$OLD_ROLLOUT" "$NEW_ROLLOUT"

OPEN_ROLLOUTS="$OLD_ROLLOUT"
lsof() {
  local rollout
  printf 'p%s\n' "${2:-0}"
  while IFS= read -r rollout; do
    [ -n "$rollout" ] && printf 'n%s\n' "$rollout"
  done <<< "$OPEN_ROLLOUTS"
}

status=""; timestamp=0
status_for_codex_pid 42 status timestamp
assert_eq idle "$status" 'initial completed rollout should be idle'
assert_eq "$OLD_ROLLOUT" "${CODEX_FILE_OF[42]:-}" 'initial rollout should be cached'

# A resumed session leaves the old file open and adds a newer one. The detector
# must replace its cache instead of continuing to parse lsof's first match.
OPEN_ROLLOUTS="$OLD_ROLLOUT"$'\n'"$NEW_ROLLOUT"
status_for_codex_pid 42 status timestamp
assert_eq busy "$status" 'new task_started event should show the working marker'
assert_eq "$NEW_ROLLOUT" "${CODEX_FILE_OF[42]:-}" 'fresher rollout should replace the cache'

# If Codex briefly closes its log handles, the refreshed mapping must survive.
OPEN_ROLLOUTS=""
status_for_codex_pid 42 status timestamp
assert_eq busy "$status" 'cached rollout should survive a closed handle'

printf '%s\n' \
  '{"timestamp":"2026-01-01T02:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}' \
  '{"timestamp":"2026-01-01T02:05:00.000Z","type":"event_msg","payload":{"type":"task_complete"}}' \
  >"$NEW_ROLLOUT"
status_for_codex_pid 42 status timestamp
assert_eq idle "$status" 'new task_complete event should show the done marker'

printf 'ok - Codex rollout selection and cache refresh\n'
