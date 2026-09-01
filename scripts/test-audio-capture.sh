#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
ARCHITECTURE=$(/usr/bin/uname -m)
PROBE_BINARY="$PROJECT_DIR/.build/direct/FlowTypeAudioCaptureProbe"

/bin/mkdir -p "$PROJECT_DIR/.build/direct"
/usr/bin/xcrun swiftc \
    -parse-as-library \
    -swift-version 5 \
    -warnings-as-errors \
    -target "$ARCHITECTURE-apple-macos13.0" \
    "$PROJECT_DIR/Sources/FlowType/Models.swift" \
    "$PROJECT_DIR/Sources/FlowType/AudioDeviceService.swift" \
    "$PROJECT_DIR/Sources/FlowType/AudioSignalQuality.swift" \
    "$PROJECT_DIR/Sources/FlowType/ProcessRunner.swift" \
    "$PROJECT_DIR/Sources/FlowType/AudioRecorder.swift" \
    "$PROJECT_DIR/Tests/AudioCaptureProbe/main.swift" \
    -o "$PROBE_BINARY" \
    -framework AVFoundation \
    -framework AudioToolbox \
    -framework CoreAudio

"$PROBE_BINARY" "${1:-system_default}"
