#!/bin/bash
# Prove the iOS and Android transports can actually talk to each other.
#
#   ./tools/run-lan-interop.sh
#
# Builds the Swift harness against the real LANTransport.swift, then pairs it with the real Kotlin
# LanTransport (as a Gradle JavaExec in the Android repo) over real Bonjour and a real TCP socket
# on this machine. Network.framework works on macOS, so no devices are needed — which is the only
# reason this can run on every change rather than once, by hand, with two phones.
#
# Two runs, so neither implementation is only ever tested in one role:
#   1. Swift hosts and echoes; Kotlin joins and drives.
#   2. Kotlin hosts and echoes; Swift joins and drives.
#
# The corpus is fixtures/protocol-v1 — the golden set both sides already agree on — sent one at a
# time and then as an unbroken burst, which is what exercises NDJSON reassembly.
set -uo pipefail
cd "$(dirname "$0")/.."

ANDROID_REPO="${ANDROID_REPO:-$HOME/Projects/PairForTwoAndroid}"
FIXTURES="$PWD/fixtures/protocol-v1"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"; kill $(jobs -p) 2>/dev/null' EXIT

command -v dns-sd >/dev/null || { echo "dns-sd not found — this harness is macOS-only"; exit 1; }
[ -d "$ANDROID_REPO" ] || { echo "Android repo not found at $ANDROID_REPO"; exit 1; }

echo "=== building the Swift harness against the real LANTransport ==="
SRC="Pair for two"
# -swift-version 5 matches what the Xcode target builds with, so this compiles the sources the same
# way the app does. It does *not* silence the Swift 6 concurrency warnings in LANTransport.swift —
# the Xcode build emits those too, and they are genuine work for whenever this moves to Swift 6.
swiftc -swift-version 5 -o "$OUT/lan-harness" \
    tools/lan-harness/main.swift \
    "$SRC/Card.swift" \
    "$SRC/CribbageModels.swift" \
    "$SRC/CribbageScorer.swift" \
    "$SRC/GameState.swift" \
    "$SRC/CribbageEngine.swift" \
    "$SRC/GameTransport.swift" \
    "$SRC/WireCodec.swift" \
    "$SRC/LANTransport.swift" || exit 1

echo "=== priming the Kotlin harness (compile once so it doesn't race the pairing) ==="
(cd "$ANDROID_REPO" && ./gradlew --quiet :core:testClasses) || exit 1

# Gradle's --args splits on whitespace, and this repo's path contains a space ("Pair for two"),
# so the Kotlin end uses its own copy of the fixtures instead. They are byte-identical — the same
# generator writes both — so this also quietly checks that the two copies haven't drifted.
kotlin_harness() {
    (cd "$ANDROID_REPO" && ./gradlew --quiet --console=plain :core:interop --args="$*")
}

diff -r "$FIXTURES" "$ANDROID_REPO/fixtures/protocol-v1" >/dev/null \
    || { echo "fixtures differ between the two repos"; exit 1; }

run_pair() {
    local label="$1"; shift
    local host_cmd="$1"; shift
    local drive_cmd="$1"; shift

    echo
    echo "=== $label ==="
    local host_log="$OUT/host.log" drive_log="$OUT/drive.log"
    : > "$host_log"; : > "$drive_log"

    eval "$host_cmd" > "$host_log" 2>&1 &
    local host_pid=$!
    sleep 2   # let the advertisement propagate before browsing starts

    eval "$drive_cmd" > "$drive_log" 2>&1
    local drive_status=$?

    wait $host_pid 2>/dev/null
    local host_status=$?

    sed 's/^/  /' "$host_log"
    sed 's/^/  /' "$drive_log"

    if [ $drive_status -ne 0 ] || [ $host_status -ne 0 ]; then
        echo "  RESULT: FAIL (driver=$drive_status host=$host_status)"
        return 1
    fi
    grep -q PASS "$drive_log" || { echo "  RESULT: FAIL (driver never reported PASS)"; return 1; }
    echo "  RESULT: PASS"
}

failed=0

run_pair "Swift hosts, Kotlin joins" \
    "'$OUT/lan-harness' --role host --mode echo --name SwiftHost --fixtures '$FIXTURES'" \
    "kotlin_harness --role guest --mode drive --name KotlinGuest --peer SwiftHost" || failed=1

run_pair "Kotlin hosts, Swift joins" \
    "kotlin_harness --role host --mode echo --name KotlinHost" \
    "'$OUT/lan-harness' --role guest --mode drive --name SwiftGuest --peer KotlinHost --fixtures '$FIXTURES'" || failed=1

echo
if [ $failed -eq 0 ]; then
    echo "ALL INTEROP CHECKS PASSED — the two transports talk in both directions."
else
    echo "INTEROP CHECKS FAILED"
fi
exit $failed
