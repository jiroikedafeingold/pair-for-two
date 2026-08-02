#!/bin/bash
# Render the game's sound effects to WAVs for the Android app.
#
#   ./tools/render-sounds.sh
#
# Compiles tools/render-sounds/main.swift against the real SoundSynthesis.swift and writes nine
# 44.1 kHz mono 16-bit WAVs into the Android repo's app/src/main/res/raw/. iOS keeps synthesizing
# these at launch from the same code; Android ships the files.
#
# The synthesis is deterministic, so a clean run leaves the WAVs byte-identical. A diff here means
# a sound actually changed — and iOS will have changed with it, which is the point.
set -euo pipefail
cd "$(dirname "$0")/.."

ANDROID_REPO="${ANDROID_REPO:-$HOME/Projects/PairForTwoAndroid}"
RAW_DIR="$ANDROID_REPO/app/src/main/res/raw"
[ -d "$ANDROID_REPO" ] || { echo "Android repo not found at $ANDROID_REPO"; exit 1; }

SRC="Pair for two"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swiftc -O -swift-version 5 -o "$OUT/render-sounds" \
    tools/render-sounds/main.swift \
    "$SRC/SoundSynthesis.swift"

mkdir -p "$RAW_DIR"
"$OUT/render-sounds" "$RAW_DIR"
