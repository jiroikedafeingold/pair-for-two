#!/bin/bash
#
# Capture the App Store screenshots for one simulator, in as many languages as you name.
#
# The app is launched once per shot with `-shot N` (see ScreenshotStage) plus the language as a
# launch argument, and simctl grabs the framebuffer. That matters: a simulator screenshot is already
# the exact pixel size Apple asks for — 2868 × 1320 on a 6.9" iPhone, 2752 × 2064 on a 13" iPad — so
# nothing is scaled or cropped afterwards, and adding a language costs one more launch.
#
#   tools/screenshots.sh "iPhone 17 Pro Max" en-US de-DE ja
#   tools/screenshots.sh "iPad Pro 13-inch (M5)" all
#
# Output: fastlane/screenshots/<App Store locale>/<device>_<n>-<name>.png
#
# Requires a Debug simulator build to exist (BuildProject, or xcodebuild -sdk iphonesimulator).
set -euo pipefail

BUNDLE_ID="com.jirofeingold5.pairfortwo"
SHOTS=(1-pegging 2-show 3-cut 4-board 5-winner)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# App Store Connect locale → the iOS language and locale to launch with. The keys are the directory
# names deliver expects; es-ES and es-MX share one translation but need their own screenshot sets,
# because a locale you don't upload keeps whatever it had.
locale_language() {
  case "$1" in
    en-US)   echo "en en_US" ;;
    es-ES)   echo "es es_ES" ;;
    es-MX)   echo "es es_MX" ;;
    fr-FR)   echo "fr fr_FR" ;;
    de-DE)   echo "de de_DE" ;;
    ja)      echo "ja ja_JP" ;;
    zh-Hans) echo "zh-Hans zh_CN" ;;
    zh-Hant) echo "zh-Hant zh_TW" ;;
    pt-BR)   echo "pt-BR pt_BR" ;;
    it)      echo "it it_IT" ;;
    ko)      echo "ko ko_KR" ;;
    tr)      echo "tr tr_TR" ;;
    *)       echo "" ;;
  esac
}

ALL_LOCALES=(en-US es-ES es-MX fr-FR de-DE ja zh-Hans zh-Hant pt-BR it ko tr)

DEVICE="${1:?usage: screenshots.sh <simulator name> <locale…|all>}"
shift
LOCALES=("$@")
if [[ "${LOCALES[0]:-}" == "all" ]]; then LOCALES=("${ALL_LOCALES[@]}"); fi

# The newest matching simulator, and a filename prefix from the device family.
UDID=$(xcrun simctl list devices available | grep -F "$DEVICE (" | tail -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[[ -n "$UDID" ]] || { echo "no available simulator named '$DEVICE'"; exit 1; }
case "$DEVICE" in
  iPad*) PREFIX="ipad13" ;;
  *)     PREFIX="iphone69" ;;
esac

APP=$(ls -dt "$HOME/Library/Developer/Xcode/DerivedData/Pair_for_two-"*/Build/Products/Debug-iphonesimulator/*.app 2>/dev/null | head -1)
[[ -n "$APP" ]] || { echo "no Debug simulator build found — build the app first"; exit 1; }

# An iPad app is resizable by default, and a resizable app doesn't get to lock its orientation — so
# the simulated iPad stays portrait and lays the game out in a portrait window. A *copy* of the bundle
# is patched to be full-screen and landscape-only, purely to take the shots; the shipping app keeps
# its multitasking support. The capture then comes out landscape-inside-a-portrait-frame, which the
# rotation pass at the end of this script straightens.
if [[ "$PREFIX" == "ipad13" ]]; then
  PATCHED="$(mktemp -d)/$(basename "$APP")"
  cp -R "$APP" "$PATCHED"
  plutil -replace UIRequiresFullScreen -bool true "$PATCHED/Info.plist"
  plutil -replace 'UISupportedInterfaceOrientations~ipad' \
    -json '["UIInterfaceOrientationLandscapeLeft","UIInterfaceOrientationLandscapeRight"]' \
    "$PATCHED/Info.plist"
  codesign -f -s - "$PATCHED" >/dev/null 2>&1 || true
  APP="$PATCHED"
fi

echo "device: $DEVICE ($UDID)"
echo "app:    $APP"
echo "locales: ${LOCALES[*]}"

xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"

for locale in "${LOCALES[@]}"; do
  read -r language applelocale <<<"$(locale_language "$locale")"
  [[ -n "$language" ]] || { echo "!! unknown locale $locale — skipped"; continue; }
  out="$ROOT/fastlane/screenshots/$locale"
  mkdir -p "$out"
  for i in "${!SHOTS[@]}"; do
    shot=$((i + 1))
    name="${SHOTS[$i]}"
    xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" \
      -shot "$shot" -AppleLanguages "($language)" -AppleLocale "$applelocale" >/dev/null
    # Long enough for the launch, the fixture's engine work, and the deal-in to settle.
    sleep 3
    xcrun simctl io "$UDID" screenshot --type=png "$out/${PREFIX}_${name}.png" 2>/dev/null
  done
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  echo "  $locale: ${#SHOTS[@]} shots"
done

# Straighten anything that came out taller than it is wide (see the iPad note above). Rotating the
# pixels is exact — no resampling, no scaling — and lands on 2752 × 2064, which is what Apple asks for.
python3 - "$ROOT/fastlane/screenshots" <<'PYTHON'
import pathlib, sys
from PIL import Image
root = pathlib.Path(sys.argv[1])
turned = 0
for path in sorted(root.glob("*/*.png")):
    with Image.open(path) as im:
        if im.height <= im.width:
            continue
        im.rotate(90, expand=True).save(path, "PNG")
        turned += 1
print(f"rotated {turned} portrait capture(s) to landscape")
PYTHON

echo "done"
