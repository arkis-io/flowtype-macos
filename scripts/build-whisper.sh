#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
VENDOR_DIR="$PROJECT_DIR/.build/vendor"

# Keep these together: the human-readable release and the immutable source commit.
WHISPER_VERSION="v1.9.1"
WHISPER_COMMIT="f049fff95a089aa9969deb009cdd4892b3e74916"
SOURCE_DIR="$VENDOR_DIR/whisper.cpp-$WHISPER_VERSION"
OUTPUT_BINARY="$VENDOR_DIR/whisper-cli-universal"

if ! command -v cmake >/dev/null 2>&1; then
    echo "CMake is required only to build FlowType releases. Install it with: brew install cmake" >&2
    exit 1
fi

/bin/mkdir -p "$VENDOR_DIR"

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
    /usr/bin/git clone \
        --branch "$WHISPER_VERSION" \
        --depth 1 \
        https://github.com/ggml-org/whisper.cpp.git \
        "$SOURCE_DIR"
fi

ACTUAL_COMMIT=$(/usr/bin/git -C "$SOURCE_DIR" rev-parse HEAD)
if [[ "$ACTUAL_COMMIT" != "$WHISPER_COMMIT" ]]; then
    echo "Pinned whisper.cpp source mismatch." >&2
    echo "Expected: $WHISPER_COMMIT" >&2
    echo "Found:    $ACTUAL_COMMIT" >&2
    echo "Remove only $SOURCE_DIR, then run this script again." >&2
    exit 1
fi

if [[ -n "$(/usr/bin/git -C "$SOURCE_DIR" status --porcelain)" ]]; then
    echo "Pinned whisper.cpp source has local changes; refusing a non-reproducible release build." >&2
    exit 1
fi

BUILT_BINARIES=()
for ARCHITECTURE in arm64 x86_64; do
    ARCH_BUILD_DIR="$VENDOR_DIR/whisper-build-$ARCHITECTURE"
    cmake \
        -S "$SOURCE_DIR" \
        -B "$ARCH_BUILD_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$ARCHITECTURE" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
        -DBUILD_SHARED_LIBS=OFF \
        -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_SERVER=OFF \
        -DWHISPER_BUILD_EXAMPLES=ON \
        -DWHISPER_CURL=OFF \
        -DGGML_NATIVE=OFF \
        -DGGML_CCACHE=OFF \
        -DGGML_OPENMP=OFF \
        -DGGML_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=ON \
        -DGGML_ACCELERATE=ON \
        -DGGML_BLAS=OFF
    cmake --build "$ARCH_BUILD_DIR" --config Release --target whisper-cli --parallel

    ARCH_BINARY="$ARCH_BUILD_DIR/bin/whisper-cli"
    if [[ ! -x "$ARCH_BINARY" ]]; then
        echo "whisper-cli was not produced for $ARCHITECTURE." >&2
        exit 1
    fi
    BUILT_BINARIES+=("$ARCH_BINARY")
done

/usr/bin/lipo -create "${BUILT_BINARIES[@]}" -output "$OUTPUT_BINARY"
/bin/chmod 755 "$OUTPUT_BINARY"

ARCHS=$(/usr/bin/lipo -archs "$OUTPUT_BINARY")
if [[ "$ARCHS" != *arm64* || "$ARCHS" != *x86_64* ]]; then
    echo "Bundled whisper-cli is not universal: $ARCHS" >&2
    exit 1
fi

DEPENDENCIES=$(/usr/bin/otool -L "$OUTPUT_BINARY")
UNSAFE_DEPENDENCIES=$(print -r -- "$DEPENDENCIES" \
    | /usr/bin/grep -E $'^\\t(@|/)' \
    | /usr/bin/grep -Ev $'^\\t(/System/Library|/usr/lib)' || true)
if [[ -n "$UNSAFE_DEPENDENCIES" ]]; then
    echo "Bundled whisper-cli still depends on a developer-machine library:" >&2
    print -r -- "$UNSAFE_DEPENDENCIES" >&2
    exit 1
fi

echo "Built self-contained whisper.cpp $WHISPER_VERSION ($WHISPER_COMMIT)"
echo "Binary: $OUTPUT_BINARY"
echo "Architectures: $ARCHS"
print -r -- "$DEPENDENCIES"
