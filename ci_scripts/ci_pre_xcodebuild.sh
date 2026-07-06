#!/bin/sh

# Xcode Cloud runs this right before xcodebuild. Stamp the build (CFBundleVersion /
# CURRENT_PROJECT_VERSION) with Xcode Cloud's own monotonically-increasing build number, so every
# TestFlight/App Store upload has a unique, higher build number — no duplicate-build-number rejections
# and no need to hand-bump before each run. The marketing version (e.g. 1.0.5) still comes from the
# project settings.
#
# Only the build number is touched, and only in the throwaway CI checkout — the repo is untouched.

set -e

if [ -z "$CI_BUILD_NUMBER" ]; then
    echo "CI_BUILD_NUMBER not set — not running under Xcode Cloud; leaving the build number as-is."
    exit 0
fi

# Xcode Cloud checks out the repo at CI_PRIMARY_REPOSITORY_PATH; the .xcodeproj lives at its root.
cd "$CI_PRIMARY_REPOSITORY_PATH"

echo "Setting build number to Xcode Cloud build $CI_BUILD_NUMBER"
xcrun agvtool new-version -all "$CI_BUILD_NUMBER"
