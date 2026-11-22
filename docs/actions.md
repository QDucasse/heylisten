# Customising heylisten

Two places to bend heylisten to your setup without rebuilding it: **action scripts** replace a
step of what the app does (focus a terminal, open the editor, notify...), and **`config.json`**
tunes the thresholds behind the avatars' states. Both are also the seams a port to another OS
would build on: a new frontend reads `ccwatch` and performs the same actions.

## Action scripts

When the app is about to do one of the steps below, it first looks for an executable
`~/.config/heylisten/actions/<action>` (`$XDG_CONFIG_HOME` if set). If there is one, it runs it
with a JSON object on stdin, and the exit code decides what happens:

| exit | meaning |
|---|---|
| `0` | done / yes. Steps that return something print it on stdout. |
| `1` | no / not found. |
| anything else, a crash, a timeout | pass: the built-in step runs instead. |

Exit 2 lets a script handle only some cases, e.g. only remote sessions, and leave the rest to
the built-in.

### Session fields

Actions about a session get these fields (plus their own, below):

```jsonc
{
  "action": "open-editor",
  "key": "sashimi|1d4aabd3-...",
  "host": "sashimi",            // "local" for this machine, else the ssh alias
  "local": false,
  "project": "flowsight",       // last component of cwd
  "cwd": "/home/me/flowsight",
  "name": "flowsight-a3",       // Claude Code session name
  "tty": "/dev/pts/4",          // or null
  "tmux": {"session": "4", "window": "@4", "pane": "%4"},   // or null
  "attach": "ssh -t ... tmux attach-session ..."           // shell command reaching the pane, or null
}
```

Frames are `{"x", "y", "width", "height"}` in points, origin at the top left of the main display.

### Actions

| action | when | extra input | stdout on exit 0 |
|---|---|---|---|
| `front-session` | **every 3 s**, and before notifying (is it already in front?) | — | `<tty> <session-id>` of the focused terminal session, only if the terminal app is in front (exit 1 otherwise) |
| `focus-terminal` | a jump to an open session | `tty` or `session` | — (exit 1: no such session) |
| `find-terminal` | a jump to a remote session attached by hand: tmux titles its window with a one-off marker | `title` | the session id showing that title |
| `current-window` | before tiling around an existing terminal | — | id of the window holding the focused session |
| `open-terminal` | a jump to a session that isn't open anywhere | session fields, `command` (shell script body that attaches) | `<session-id> <window-id>` of the new window |
| `place-window` | tiling the terminal | `window`, `frame` | — |
| `editor-has-window` | after focusing a session: is the project open in the editor? | session fields | — (exit 0 yes, 1 no) |
| `open-editor` | the project isn't open in the editor | session fields, `frame` | — |
| `new-workspace` | before `open-terminal`, if "open on a new desktop" is on | — | — |
| `notify` | Claude needs you, finished, or hit an error | session fields, `title`, `subtitle`, `body`, `sound`, `id` | — |

Session and window ids are whatever your terminal uses: the app only stores them and hands them
back (it remembers which window shows which remote tmux session).

The built-ins: iTerm2 (terminal), VS Code (editor), Mission Control + Accessibility (desktops,
tiling), the macOS notification centre. Steps run from the app's process: output on stderr is
dropped, and failures are logged to `~/Library/Logs/heylisten.log`.

### Examples

No editor at all (just the terminal):

```sh
#!/bin/sh
# ~/.config/heylisten/actions/editor-has-window
exit 0   # "already open": never open one
```

Zed instead of VS Code, local projects only:

```sh
#!/bin/sh
# ~/.config/heylisten/actions/open-editor
input=$(cat)
[ "$(echo "$input" | jq -r .local)" = true ] || exit 2   # remote: let the built-in handle it
zed "$(echo "$input" | jq -r .cwd)"
```

On Linux with sway and kitty, a frontend could name each window it opens and find it again by
that name:

```sh
#!/bin/sh
# open-terminal: the window title doubles as its session and window id
input=$(cat)
id="heylisten-$(echo "$input" | jq -r '.host + "-" + .tmux.session')"
echo "$input" | jq -r .command > "/tmp/$id.sh"
setsid kitty --title "$id" sh "/tmp/$id.sh" >/dev/null 2>&1 &
echo "$id $id"
```

```sh
#!/bin/sh
# focus-terminal: by the id from open-terminal; leave tty lookups to someone else
id=$(jq -r '.session // empty')
[ -n "$id" ] || exit 2
swaymsg "[title=\"^$id\$\"] focus" >/dev/null || exit 1
```

```sh
#!/bin/sh
# notify
input=$(cat)
notify-send "$(echo "$input" | jq -r .title)" "$(echo "$input" | jq -r .body)"
```

## Thresholds: `config.json`

`ccwatch` decides each session's states, so every frontend agrees. Any of these keys in
`~/.config/heylisten/config.json` on **the host running the session** overrides the default; edits
apply within a second.

| key | default | |
|---|---|---|
| `contextWindow` | `1000000` | context window size, tokens |
| `contextHigh` | `0.6` | fraction of the window: a flame on the head |
| `contextFull` | `0.8` | fraction: auto-compaction is close, a bigger flame |
| `cacheTtl` | `3600` | prompt cache lifetime (s) when the transcript doesn't say |
| `longTurn` | `600` | busy this long (s): sweat drop |
| `compactStale` | `600` | ignore a compaction marker older than this (s) |
| `agentStale` | `10800` | ignore a subagent marker older than this (s) |

## Writing another frontend

`ccwatch` (in `remote/`, Python 3 standard library only) prints one JSON object per line: a
`hello` (`version`, `host`, `time`), then a `snapshot` whenever anything changes (`sessions`,
`tmux`), and a `heartbeat` every 15 s. Run it locally, or over `ssh host ~/.local/share/heylisten/ccwatch`
for remote hosts. Each session carries its raw facts (`status`, `attention`, `tmux`, `tty`...)
and the states decided from them (`contextLevel`, `cacheCold`, `compacting`, `subagents`,
`longTurn`); see `WireSession` in `app/Sources/HeyListen/Model.swift`. A frontend draws those and
calls the actions above.
