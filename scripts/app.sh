#!/bin/bash
# Flutter app helper (macOS).
#
# The project lives in ~/Documents, which iCloud syncs; iCloud adds extended
# attributes that make codesign fail ("resource fork, Finder information, or
# similar detritus not allowed"). So app/ is mirrored to a folder outside iCloud
# and everything runs there.
#
#   scripts/app.sh test       run the Dart unit tests
#   scripts/app.sh build      release build for iOS
#   scripts/app.sh install    build, then install + launch on every connected iPhone
set -euo pipefail
export PATH=/opt/homebrew/bin:$PATH
SRC="$(cd "$(dirname "$0")/.." && pwd)/app"
WORK="$HOME/.flutter-builds/distance-bits"
BUNDLE=us.johnsonfarms.distanceBits
mkdir -p "$WORK"
rsync -a --delete --exclude build --exclude .dart_tool --exclude ios/Pods --exclude ios/.symlinks --exclude ios/Podfile.lock "$SRC/" "$WORK/"
cd "$WORK"
flutter pub get >/dev/null

case "${1:-build}" in
  test)
    flutter test
    ;;
  build|install)
    flutter build ios --release
    if [ "${1}" = "install" ]; then
      APP="$WORK/build/ios/iphoneos/Runner.app"
      xcrun devicectl list devices --json-output /tmp/db-devices.json >/dev/null 2>&1
      IDS=$(/usr/bin/python3 -c '
import json
for x in json.load(open("/tmp/db-devices.json"))["result"]["devices"]:
    hp = x.get("hardwareProperties", {}); cp = x.get("connectionProperties", {})
    if hp.get("deviceType") == "iPhone" and cp.get("pairingState") == "paired" and cp.get("tunnelState") != "unavailable":
        print(x["identifier"], hp.get("marketingName", "").replace(" ", "_"))
')
      echo "$IDS" | while read -r id name; do
        [ -z "$id" ] && continue
        echo "== installing on $name ($id)"
        if xcrun devicectl device install app --device "$id" "$APP" >/tmp/db-install.log 2>&1; then
          xcrun devicectl device process launch --device "$id" "$BUNDLE" >/dev/null 2>&1 && echo "   installed and launched" || echo "   installed (launch failed: is the phone locked?)"
        else
          echo "   install FAILED:"; tail -5 /tmp/db-install.log
        fi
      done
    fi
    ;;
  *) echo "usage: $0 test|build|install"; exit 2 ;;
esac
