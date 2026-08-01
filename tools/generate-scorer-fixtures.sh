#!/bin/bash
# Regenerate the scorer differential fixtures from the shipping iOS scorer.
#
#   ./tools/generate-scorer-fixtures.sh
#
# Compiles tools/scorer-fixtures/main.swift against the real CribbageScorer with the Command Line
# Tools toolchain — no Xcode, no simulator, no test target. Output goes to fixtures/scorer-v1/,
# which is copied into the Android repo and asserted by :core's ScorerFixtureTest.
#
# The corpus is deterministic, so a clean run leaves the fixtures byte-identical. If this produces
# a diff, the iOS scorer's behaviour changed — and Android needs the same change.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Pair for two"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swiftc -O -o "$OUT/scorer-fixtures" \
    tools/scorer-fixtures/main.swift \
    "$SRC/Card.swift" \
    "$SRC/CribbageModels.swift" \
    "$SRC/CribbageScorer.swift"

"$OUT/scorer-fixtures" fixtures/scorer-v1
