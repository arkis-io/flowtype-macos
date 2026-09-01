#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
VENDOR_DIR="$PROJECT_DIR/.build/vendor"
MODEL_PATH="$VENDOR_DIR/ggml-silero-v6.2.0.bin"
STAGING_PATH="$MODEL_PATH.download"
MODEL_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin"
EXPECTED_BYTES=885098
EXPECTED_SHA256="2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"

/bin/mkdir -p "$VENDOR_DIR"

verify_model() {
    local path=$1
    [[ -f "$path" ]] || return 1
    local actual_bytes=$(/usr/bin/stat -f %z "$path")
    [[ "$actual_bytes" == "$EXPECTED_BYTES" ]] || return 1
    local actual_sha=$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}')
    [[ "$actual_sha" == "$EXPECTED_SHA256" ]]
}

if verify_model "$MODEL_PATH"; then
    exit 0
fi

/bin/rm -f "$STAGING_PATH"
/usr/bin/curl \
    --fail \
    --location \
    --retry 3 \
    --connect-timeout 20 \
    --output "$STAGING_PATH" \
    "$MODEL_URL"

if ! verify_model "$STAGING_PATH"; then
    /bin/rm -f "$STAGING_PATH"
    echo "The pinned voice-activity model failed verification." >&2
    exit 1
fi

/bin/mv "$STAGING_PATH" "$MODEL_PATH"
