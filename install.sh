#!/bin/sh
# Place jig at ~/.local/bin/jig. Not a daemon, so no launchd — a
# single-shot CLI on PATH is all there is.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin/jig"

"$DIR/build.sh"

mkdir -p "$HOME/.local/bin"
install -m 0755 "$DIR/bin/jig" "$BIN"

echo "installed: $BIN"

# PATH 通ってる? 通ってなければ案内。
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "note: $HOME/.local/bin が PATH に無い。.zshrc / .bashrc に追加してください:"
       echo "      export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
