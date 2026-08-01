#!/bin/bash
# Verify the wire protocol implementation and regenerate the golden fixtures.
#
#   ./tools/verify-protocol.sh
#
# Compiles tools/protocol-check/main.swift against the real model sources with the Command
# Line Tools toolchain — no Xcode, no simulator, no test target required. Everything it
# touches is pure Foundation.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Pair for two"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swiftc -o "$OUT/protocol-check" \
    tools/protocol-check/main.swift \
    "$SRC/Card.swift" \
    "$SRC/CribbageModels.swift" \
    "$SRC/GameState.swift" \
    "$SRC/GameTransport.swift" \
    "$SRC/CribbageScorer.swift" \
    "$SRC/WireCodec.swift"

"$OUT/protocol-check" fixtures/protocol-v1
