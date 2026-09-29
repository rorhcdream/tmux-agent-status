#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-status-startup.XXXXXX")"
TMUX_BIN="$(command -v tmux)"
TEST_SOCKET="$TEST_DIR/tmux.sock"
cleanup() {
  "$TMUX_BIN" -S "$TEST_SOCKET" kill-server 2>/dev/null || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Route entry-point queries to an isolated server even with TMUX unset.
# The poller also receives the real socket from #{socket_path}.
mkdir "$TEST_DIR/bin"
cat >"$TEST_DIR/bin/tmux" <<'WRAPPER'
#!/usr/bin/env bash
exec "$STARTUP_TEST_TMUX" -S "$STARTUP_TEST_SOCKET" "$@"
WRAPPER
chmod +x "$TEST_DIR/bin/tmux"
export STARTUP_TEST_TMUX="$TMUX_BIN" STARTUP_TEST_SOCKET="$TEST_SOCKET"
export PATH="$TEST_DIR/bin:$PATH"
export STARTUP_TEST_ENTRY="$ROOT_DIR/agent-status.tmux"
printf '%s\n' 'run-shell "env -u TMUX bash \"$STARTUP_TEST_ENTRY\""' >"$TEST_DIR/tmux.conf"
env -u TMUX "$TMUX_BIN" -S "$TEST_SOCKET" -f "$TEST_DIR/tmux.conf" new-session -d -s startup

poller_pid=""
for _wait in {1..50}; do
  poller_pid="$(tmux show-option -gqv @agent_status_pid)"
  [ -n "$poller_pid" ] && kill -0 "$poller_pid" 2>/dev/null && break
  sleep 0.1
done
[ -n "$poller_pid" ] && kill -0 "$poller_pid" 2>/dev/null || {
  printf 'not ok - cold startup without TMUX did not launch the poller\n' >&2
  exit 1
}
# Ensure the detached process survives beyond launch, then reload the plugin.
sleep 1
kill -0 "$poller_pid"
env -u TMUX bash "$ROOT_DIR/agent-status.tmux"
[ "$(tmux show-option -gqv @agent_status_pid)" = "$poller_pid" ] || {
  printf 'not ok - reload launched a duplicate poller\n' >&2
  exit 1
}
printf 'ok - cold startup without TMUX and single-instance reload\n'
