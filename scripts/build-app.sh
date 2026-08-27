#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_DIR="$PROJECT_DIR/dist/FlowType.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUILD_DIR="$PROJECT_DIR/.build/direct"
ARCHITECTURE=$(/usr/bin/uname -m)

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$BUILD_DIR"

/usr/bin/xcrun swiftc \
    -parse-as-library \
    -swift-version 5 \
    -target "$ARCHITECTURE-apple-macos13.0" \
    "$PROJECT_DIR"/Sources/FlowType/*.swift \
    -o "$MACOS_DIR/FlowType" \
    -framework AppKit \
    -framework AVFoundation \
    -framework AudioToolbox \
    -framework CoreAudio \
    -framework CoreGraphics \
    -framework ServiceManagement \
    -framework ApplicationServices \
    -framework UniformTypeIdentifiers

/bin/cp "$PROJECT_DIR/Support/Info.plist" "$CONTENTS_DIR/Info.plist"
/bin/cp "$PROJECT_DIR/Resources/FlowType.icns" "$RESOURCES_DIR/FlowType.icns"
/usr/bin/codesign --force --deep --sign - "$APP_DIR"

echo "Built $APP_DIR"
