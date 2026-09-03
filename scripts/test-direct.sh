#!/bin/zsh
set -euo pipefail

# Compiles every app source file (except the @main entry point) together with
# the project-owned direct test suite, so a newly added source file is covered
# automatically instead of requiring a manual addition here. The framework list
# mirrors scripts/build-app.sh so the test binary sees the same dependencies
# the app does.

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
TEST_BINARY="$PROJECT_DIR/.build/direct/FlowTypeManualTests"
ARCHITECTURE=$(/usr/bin/uname -m)

mkdir -p "$PROJECT_DIR/.build/direct"

# FlowTypeMain.swift declares @main; Tests/ManualTests/main.swift supplies the test entry point.
APP_SOURCES=("$PROJECT_DIR"/Sources/FlowType/*.swift)
APP_SOURCES=(${APP_SOURCES:#*/Sources/FlowType/FlowTypeMain.swift})

/usr/bin/xcrun swiftc \
    -swift-version 5 \
    -target "$ARCHITECTURE-apple-macos13.0" \
    -warnings-as-errors \
    "${APP_SOURCES[@]}" \
    "$PROJECT_DIR/Tests/ManualTests/main.swift" \
    -o "$TEST_BINARY" \
    -framework AppKit \
    -framework AVFoundation \
    -framework AudioToolbox \
    -framework CoreAudio \
    -framework CoreGraphics \
    -framework CryptoKit \
    -framework ServiceManagement \
    -framework ApplicationServices \
    -framework UniformTypeIdentifiers

"$TEST_BINARY"
