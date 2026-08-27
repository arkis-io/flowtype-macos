#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
TEST_BINARY="$PROJECT_DIR/.build/direct/FlowTypeManualTests"
ARCHITECTURE=$(/usr/bin/uname -m)

mkdir -p "$PROJECT_DIR/.build/direct"

/usr/bin/xcrun swiftc \
    -swift-version 5 \
    -target "$ARCHITECTURE-apple-macos13.0" \
    "$PROJECT_DIR/Sources/FlowType/Models.swift" \
    "$PROJECT_DIR/Sources/FlowType/AudioSignalQuality.swift" \
    "$PROJECT_DIR/Sources/FlowType/GestureStateMachine.swift" \
    "$PROJECT_DIR/Sources/FlowType/PersonalDictionary.swift" \
    "$PROJECT_DIR/Sources/FlowType/PermissionSetupStep.swift" \
    "$PROJECT_DIR/Sources/FlowType/SettingsValidation.swift" \
    "$PROJECT_DIR/Tests/ManualTests/main.swift" \
    -o "$TEST_BINARY"

"$TEST_BINARY"
