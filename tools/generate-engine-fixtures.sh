#!/bin/bash
# Regenerate the engine differential fixtures from the shipping iOS referee.
#
#   ./tools/generate-engine-fixtures.sh
#
# Compiles tools/engine-fixtures/main.swift against the real CribbageEngine with the Command Line
# Tools toolchain — no Xcode, no simulator, no test target. Output goes to fixtures/engine-v1/,
# which is copied into the Android repo and asserted by :core's EngineFixtureTest.
#
# The corpus is deterministic, so a clean run leaves the fixtures byte-identical. If this produces
# a diff, the iOS referee's behaviour changed — and Android needs the same change.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Pair for two"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/engine-fixtures" \
    tools/engine-fixtures/main.swift \
    "$SRC/Card.swift" \
    "$SRC/CribbageModels.swift" \
    "$SRC/CribbageScorer.swift" \
    "$SRC/GameState.swift" \
    "$SRC/CribbageEngine.swift"

"$OUT/engine-fixtures" fixtures/engine-v1
