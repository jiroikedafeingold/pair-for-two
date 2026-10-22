#!/bin/bash
#
# Capture App Store screenshots on the iPhone Duo simulator, one display and pose at a time.
# The Duo can't be folded or turned from the command line, so set the pose up in DeviceHub first,
# then run this for it:
#
#   tools/duo-screenshots.sh primary-1 01-inner-landscape 1 2 3 4   # unfolded, held sideways
#   tools/duo-screenshots.sh primary-1 02-inner-portrait 1 2 4      # unfolded, held upright
#   tools/duo-screenshots.sh primary 03-cover 1 3 4                 # folded: the cover screen
#
# The numbers are `-shot N` fixtures (see ScreenshotStage). Output goes to
# Marketing/screenshots/iphone-duo/<locale>/duo_<pose>_<shot>.png, so the pose's prefix sets the
# order on the store; set LOCALES to limit the languages. App Store Connect takes all three sizes in
# one APP_IPHONE_DUO set, at most 10 per language. Upload with tools/upload-duo-screenshots.rb.
set -euo pipefail
cd "$(dirname "$0")/.."

UDID=$(xcrun simctl list devices booted | grep -F "iPhone Duo (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[[ -n "$UDID" ]] || { echo "boot the iPhone Duo simulator first"; exit 1; }
BUNDLE_ID="com.jirofeingold5.pairfortwo"
DISPLAY_ID=${1:?display: primary-1 (inner) or primary (cover)}
POSE=${2:?pose name}
shift 2
NUMS=("$@")
eval "$(sed -n '/^locale_language()/,/^}/p' tools/screenshots.sh)"
NAMES=(x 1-pegging 2-show 3-cut 4-board 5-winner)

# A throwaway launch first, as in screenshots.sh: the first one after an install is the slow one.
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" -shot 1 >/dev/null
sleep 8

for locale in ${LOCALES:-en-US es-ES es-MX fr-FR de-DE ja zh-Hans zh-Hant pt-BR it ko tr}; do
  read -r language applelocale <<<"$(locale_language "$locale")"
  out="Marketing/screenshots/iphone-duo/$locale"
  mkdir -p "$out"
  for n in "${NUMS[@]}"; do
    xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" \
      -shot "$n" -AppleLanguages "($language)" -AppleLocale "$applelocale" >/dev/null
    # Longer than screenshots.sh waits: the launch screen is still fading out at three seconds.
    sleep 5
    xcrun simctl io "$UDID" screenshot --display="$DISPLAY_ID" --type=png \
      "$out/duo_${POSE}_${NAMES[$n]}.png" >/dev/null 2>&1
  done
  echo "  $locale done"
done

# Leave the real app running rather than a fixture, whose Quit has no menu to go back to.
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" >/dev/null
