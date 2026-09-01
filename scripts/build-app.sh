#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_DIR="$PROJECT_DIR/dist/FlowType.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUILD_DIR="$PROJECT_DIR/.build/direct"
REQUESTED_ARCHS=${FLOWTYPE_ARCHS:-native}
BUNDLE_WHISPER=${FLOWTYPE_BUNDLE_WHISPER:-1}

case "$REQUESTED_ARCHS" in
    native)
        ARCHITECTURES=($(/usr/bin/uname -m))
        ;;
    universal)
        ARCHITECTURES=(arm64 x86_64)
        ;;
    arm64|x86_64)
        ARCHITECTURES=($REQUESTED_ARCHS)
        ;;
    *)
        echo "FLOWTYPE_ARCHS must be native, universal, arm64, or x86_64" >&2
        exit 2
        ;;
esac

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$BUILD_DIR"

BUILT_BINARIES=()
for ARCHITECTURE in "${ARCHITECTURES[@]}"; do
    ARCH_BINARY="$BUILD_DIR/FlowType-$ARCHITECTURE"
    /usr/bin/xcrun swiftc \
        -parse-as-library \
        -swift-version 5 \
        -warnings-as-errors \
        -target "$ARCHITECTURE-apple-macos13.0" \
        "$PROJECT_DIR"/Sources/FlowType/*.swift \
        -o "$ARCH_BINARY" \
        -framework AppKit \
        -framework AVFoundation \
        -framework AudioToolbox \
        -framework CoreAudio \
        -framework CoreGraphics \
        -framework CryptoKit \
        -framework ServiceManagement \
        -framework ApplicationServices \
        -framework UniformTypeIdentifiers
    BUILT_BINARIES+=("$ARCH_BINARY")
done

if (( ${#BUILT_BINARIES[@]} == 1 )); then
    /bin/cp "${BUILT_BINARIES[1]}" "$MACOS_DIR/FlowType"
else
    /usr/bin/lipo -create "${BUILT_BINARIES[@]}" -output "$MACOS_DIR/FlowType"
fi

/bin/cp "$PROJECT_DIR/Support/Info.plist" "$CONTENTS_DIR/Info.plist"
/bin/cp "$PROJECT_DIR/Resources/FlowType.icns" "$RESOURCES_DIR/FlowType.icns"
/bin/cp "$PROJECT_DIR/LICENSE" "$RESOURCES_DIR/LICENSE.txt"
/bin/cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"
/bin/mkdir -p "$RESOURCES_DIR/ThirdPartyLicenses"
/bin/cp "$PROJECT_DIR"/ThirdPartyLicenses/*.txt "$RESOURCES_DIR/ThirdPartyLicenses/"

if [[ "$BUNDLE_WHISPER" == "1" ]]; then
    WHISPER_BINARY="$PROJECT_DIR/.build/vendor/whisper-cli-universal"
    if [[ ! -x "$WHISPER_BINARY" ]]; then
        "$PROJECT_DIR/scripts/build-whisper.sh"
    fi
    /bin/mkdir -p "$RESOURCES_DIR/Whisper/bin"
    /bin/cp "$WHISPER_BINARY" "$RESOURCES_DIR/Whisper/bin/whisper-cli"
    /bin/chmod 755 "$RESOURCES_DIR/Whisper/bin/whisper-cli"
    /usr/bin/codesign --force --sign - "$RESOURCES_DIR/Whisper/bin/whisper-cli"

    "$PROJECT_DIR/scripts/fetch-vad-model.sh"
    /bin/mkdir -p "$RESOURCES_DIR/Whisper/models"
    /bin/cp \
        "$PROJECT_DIR/.build/vendor/ggml-silero-v6.2.0.bin" \
        "$RESOURCES_DIR/Whisper/models/ggml-silero-v6.2.0.bin"
fi

/usr/bin/codesign --force --sign - "$APP_DIR"

echo "Built $APP_DIR for: $(/usr/bin/lipo -archs "$MACOS_DIR/FlowType")"
