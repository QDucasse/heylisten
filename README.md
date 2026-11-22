# heylisten

*Hey! Listen!* An idle macOS widget showing your Claude Code sessions (local and over SSH) as
little pixel mascots. It notifies you when one needs you and takes you to its tmux pane in a click.

```sh
./install.sh                 # watcher + hooks on this Mac
./install.sh myserver        # ...and on remote hosts
scripts/build-app.sh         # -> build/HeyListen.app
open build/HeyListen.app
```

Then add remote hosts from the menu bar icon: **Hosts → Edit remote hosts…**.

To use another terminal or editor, change the thresholds, or write a frontend for another OS,
see [docs/actions.md](docs/actions.md).
