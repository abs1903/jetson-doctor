#!/bin/sh
# install: copies jetson-doctor.sh to ~/.local/bin and verifies it runs
set -e
SRC="$(cd "$(dirname "$0")" && pwd)/jetson-doctor.sh"
DEST="${HOME}/.local/bin/jetson-doctor"
mkdir -p "$HOME/.local/bin"
cp "$SRC" "$DEST"
chmod +x "$DEST"
echo "installed: $DEST"
"$DEST" --help
