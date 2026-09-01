#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${SIGN_IDENTITY:=Apple Development}"
cd "$ROOT"
swift build -c release
BIN_DIR=$(cd "$ROOT" && swift build -c release --show-bin-path)
APP="$ROOT/.build/TailDesk.app"

mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/TailDesk.icns" "$APP/Contents/Resources/TailDesk.icns"
cp "$BIN_DIR/TailDesk" "$APP/Contents/MacOS/TailDesk"
codesign --force --sign "$SIGN_IDENTITY" --identifier com.xinzhang.taildesk --options runtime --timestamp=none "$APP" >/dev/null

echo "$APP"
