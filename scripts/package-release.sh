#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_DIR="$PROJECT_DIR/dist/FlowType.app"
RELEASE_ARCHS=${FLOWTYPE_RELEASE_ARCHS:-universal}

"$PROJECT_DIR/scripts/test-direct.sh"
"$PROJECT_DIR/scripts/build-whisper.sh"
FLOWTYPE_ARCHS=$RELEASE_ARCHS "$PROJECT_DIR/scripts/build-app.sh"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_DIR/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_DIR/Contents/Info.plist")
ARCHS=$(/usr/bin/lipo -archs "$APP_DIR/Contents/MacOS/FlowType")

if [[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]]; then
    ARCH_LABEL=universal
else
    ARCH_LABEL=${ARCHS// /-}
fi

RELEASE_BASENAME="FlowType-$VERSION-macos-$ARCH_LABEL"
STAGING_DIR="$PROJECT_DIR/.build/release/$RELEASE_BASENAME"
DMG_PATH="$PROJECT_DIR/dist/$RELEASE_BASENAME.dmg"
CHECKSUM_PATH="$DMG_PATH.sha256"

/bin/rm -rf "$STAGING_DIR"
/bin/mkdir -p "$STAGING_DIR"
/usr/bin/ditto "$APP_DIR" "$STAGING_DIR/FlowType.app"
/bin/ln -s /Applications "$STAGING_DIR/Applications"
/bin/cp "$PROJECT_DIR/docs/INSTALL_FOR_FRIENDS.md" "$STAGING_DIR/READ ME FIRST.md"
/bin/cp "$PROJECT_DIR/LICENSE" "$STAGING_DIR/LICENSE.txt"
/bin/cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$STAGING_DIR/THIRD PARTY NOTICES.md"
/bin/cp -R "$PROJECT_DIR/ThirdPartyLicenses" "$STAGING_DIR/ThirdPartyLicenses"

/bin/rm -f "$DMG_PATH" "$CHECKSUM_PATH"
/usr/bin/hdiutil create \
    -volname "FlowType $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

CHECKSUM=$(/usr/bin/shasum -a 256 "$DMG_PATH" | /usr/bin/awk '{print $1}')
print -r -- "$CHECKSUM  ${DMG_PATH:t}" > "$CHECKSUM_PATH"
(cd "${DMG_PATH:h}" && /usr/bin/shasum -a 256 -c "${CHECKSUM_PATH:t}")

echo "Packaged FlowType $VERSION (build $BUILD) for $ARCHS"
echo "DMG: $DMG_PATH"
echo "SHA-256: $CHECKSUM_PATH"
