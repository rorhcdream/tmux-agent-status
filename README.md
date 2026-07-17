# tmux-agent-status

A tmux plugin that shows each coding agent's status in your tmux window list,
driven by the agent's **own on-disk session state** instead of hooks. Supports
**Claude Code** and **Codex**.

## Why this exists

Hook-based status trackers (e.g. the official `workmux-status` plugin) wire
`UserPromptSubmit`/`PostToolUse` → working and `Stop` → done. That breaks for some
sessions: when you interrupt a turn with `Esc`, Claude fires **no hook**, so the
window stays stuck on the working icon 🤖.

This plugin sidesteps hooks entirely. Claude Code writes authoritative live status
to `~/.claude/sessions/<pid>.json`:

```json
{ "pid": 67550, "cwd": "...", "status": "busy", "statusUpdatedAt": 1781601161403 }
```

`status` is one of `busy` / `idle` / `waiting` / `shell`, and Claude updates it on
every transition — **including interrupts**. A small daemon polls these files, maps
each Claude PID back to its tmux pane (pane → `pane_pid` → child `claude` process),
and sets a tmux status option accordingly. Reading ground truth means no stuck icons
and no false positives on long, quiet generations.

### Codex

Codex has no per-pid status file — it writes an append-only event log per session
(`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`). The daemon bridges a running
`codex` process to its log via the file it holds open (`lsof`, then cached per pid so
the mapping survives the handle closing between turns), and derives status from the
last turn-boundary event: `task_started` → working, `task_complete` → done,
`turn_aborted` → cleared. Everything downstream (icons, sticky-done, recency) is shared
with the Claude path, so a codex pane looks identical.

## Status mapping

| Claude `status` | tmux icon            |
| --------------- | -------------------- |
| `busy`, `shell` | 🤖 working           |
| `waiting`       | 💬 waiting (until you view the window) |
| `idle`          | ✅ done — **sticky** until you view the window once |
| no agent proc   | (icon cleared)       |

(Codex maps its `task_started` / `task_complete` / `turn_aborted` events onto the
same working / done / cleared states.)

### Sticky "done" (show until checked)

When a session finishes, its ✅ stays in the window list until you actually switch
to that window. Once viewed, it clears and stays quiet — it will **not** re-appear
until the *next* completion. `waiting` behaves similarly but re-appears if it's still
waiting after you look away, since it needs your input.

The "viewed" signal comes from an `after-select-window` hook the plugin installs: the
instant you select a window it stamps that window with a `@agent_status_seen`
timestamp. The daemon clears the done icon once a window's seen-stamp is newer than the
completion. Using a hook (rather than only sampling `#{window_active}` each poll) means
even a visit shorter than one poll interval clears the icon, and the seen-state lives in
tmux window options so it survives daemon restarts.

### Recency marker (recently-used sessions)

Sessions whose last status change was within `@agent_status_recent_days` (default 3)
get a small marker appended to their icon, e.g. `✅ •`; sessions untouched for longer
show just the bare icon. This gives an at-a-glance sense of which windows you've been
working in recently. Customize with `@agent_status_recent_marker`, or set
`@agent_status_recent_days 0` to disable.

```
win 1: ✅ •   (active 2h ago)
win 2: ✅ •   (active yesterday)
win 3: ✅     (active 5 days ago)
win 4: 🤖 •   (working now)
```

## Requirements

- **bash 4+** and **tmux 3.0+**
- **jq** — parses Claude session JSON and Codex event logs
- **lsof** — maps a running `codex` process to its session log (not needed for
  Claude-only setups)
- standard process tools (`ps`)

## Install

### With TPM

```tmux
# ~/.tmux.conf
set -g @plugin 'rorhcdream/tmux-agent-status'   # or a local path
run '~/.tmux/plugins/tpm/tpm'
```

### Local (no TPM)

```tmux
# ~/.tmux.conf
run-shell '~/personal/tmux-agent-status/agent-status.tmux'
```

Reload tmux (`tmux source-file ~/.tmux.conf`). The daemon starts automatically and
is single-instanced per tmux server.

## Uninstall

Remove the `run-shell`/`@plugin` line from `~/.tmux.conf`. To stop it in the running
server without restarting:

```sh
bash ~/personal/tmux-agent-status/agent-status.tmux stop
```

That kills the daemon and clears all icons. Nothing is written to disk, so there's
nothing else to remove (a restart of the tmux server would also fully reset it).

This plugin is self-contained — no workmux, no Claude hooks. By default it writes to
its own `@agent_status` variable and wires it into your window list automatically.

## Configuration

```tmux
set -g @agent_status_interval 2          # poll seconds (default 2)
set -g @agent_status_working  '🤖'
set -g @agent_status_waiting  '💬'
set -g @agent_status_done     '✅'
set -g @agent_status_var      '@agent_status'   # tmux option the icon is written to
set -g @agent_status_set_format 1        # wire window-status-format (default on)
set -g @agent_status_recent_marker '•'   # marker for sessions active recently
set -g @agent_status_recent_days   3     # "recent" window in days (0 disables)
```

The icon is written to the tmux user-option named by `@agent_status_var` (default
`@agent_status`). With `@agent_status_set_format` on (the default), the plugin
**injects** the status slot into your existing `window-status-format` /
`window-status-current-format` — preserving any custom theming — and only falls back
to a built-in default if you have no format set. Set `@agent_status_set_format 0` if
you'd rather place `#{@agent_status}` in your format yourself.

## How it works

- `agent-status.tmux` — entry point tmux runs on load. Launches the daemon detached
  (via `setsid`), single-instanced through the `@agent_status_pid` server option, and
  passes the tmux socket so the daemon targets the right server.
- `scripts/poller.sh` — the loop: snapshot processes, find every `claude`/`codex`
  descendant of each pane's `pane_pid`, read each one's status, pick the **most active**
  (working > waiting > done) when a pane runs several, and reconcile the status option
  (only writing when the value actually changes).

## Caveats

- **Reads an undocumented Claude Code file** (`~/.claude/sessions/<pid>.json`, schema
  observed on v2.1.178). A future Claude release could change the format or status
  values; parsing is defensive but may need updating.
- Respects `CLAUDE_CONFIG_DIR` for locating the sessions directory (all `~/.claude*`
  configs are scanned).
- The status option is window-level: if one window runs several agents (e.g. a claude
  and a codex side by side) they share a single icon, showing the **most active** one
  (working > waiting > done).
- The daemon lives as long as the tmux server; it exits on its own when the server
  goes away.
