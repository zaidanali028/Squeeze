#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
"$ROOT/build.sh"

DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/Squeeze.app"
cp -R "$ROOT/build/Squeeze.app" "$DEST/Squeeze.app"
xattr -cr "$DEST/Squeeze.app" 2>/dev/null || true

mkdir -p "$HOME/.local/bin"
ln -sf "$DEST/Squeeze.app/Contents/MacOS/squeeze-cli" "$HOME/.local/bin/squeeze"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$DEST/Squeeze.app" || true
fi

echo "Installed: $DEST/Squeeze.app"
echo "CLI:       $HOME/.local/bin/squeeze"
echo
echo "Open it with: open \"$DEST/Squeeze.app\""
