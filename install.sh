#!/usr/bin/env bash
# heylisten installer: watcher + Claude Code hooks.
#
#   ./install.sh                  install on this machine
#   ./install.sh myserver other   install on remote hosts (over ssh)
#   ./install.sh --uninstall [host...]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
dest='.local/share/heylisten'
files=(ccwatch hook.py install_hooks.py)
flag=""
hosts=()
for a in "$@"; do
  case "$a" in
    --uninstall) flag="--uninstall" ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) hosts+=("$a") ;;
  esac
done

install_local() {
  mkdir -p "$HOME/$dest"
  for f in "${files[@]}"; do cp "$here/remote/$f" "$HOME/$dest/$f"; done
  chmod +x "$HOME/$dest/ccwatch" "$HOME/$dest/hook.py"
  python3 "$HOME/$dest/install_hooks.py" $flag
  echo "local: ccwatch v$("$HOME/$dest/ccwatch" --version)"
}

install_remote() {
  local h="$1"
  local ssh=(ssh -T -o ClearAllForwardings=yes "$h")
  # Ship files as a tar stream: one connection, no scp quirks.
  COPYFILE_DISABLE=1 tar --no-xattrs -C "$here/remote" -cf - "${files[@]}" |
    "${ssh[@]}" "mkdir -p ~/$dest && tar -C ~/$dest -xf - && chmod +x ~/$dest/ccwatch ~/$dest/hook.py && python3 ~/$dest/install_hooks.py $flag && echo \"$h: ccwatch v\$(~/$dest/ccwatch --version)\""
}

if [ ${#hosts[@]} -eq 0 ]; then
  install_local
else
  for h in "${hosts[@]}"; do install_remote "$h"; done
fi
