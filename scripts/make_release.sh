#!/bin/bash
# Official release package: Developer ID signed, notarized by Apple, stapled DMG.
#   scripts/make_release.sh build     build SADROG.app from the committed source into $DIST/<version>/ (signed, hardened runtime)
#   scripts/make_release.sh package   notarize + staple the app, make the DMG, sign + notarize + staple it, verify, write checksums
# Environment: SADROG_BUILD_DIR (default external build folder), NOTARY_PROFILE (default gdc-notary, a Keychain profile).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT="${SADROG_BUILD_DIR:-$HOME/sadrog-build}"
mkdir -p "$EXT" 2>/dev/null; [ -w "$EXT" ] || { echo "Build folder not writable: set SADROG_BUILD_DIR"; exit 2; }
ID="${SADROG_SIGN_IDENTITY:-Developer ID Application: DUMITRU CRISTINEL GORDAS (8AR6XP8MG7)}"
PROFILE="${NOTARY_PROFILE:-gdc-notary}"
cd "$ROOT"
[ -z "$(git status --porcelain)" ] || { echo "Arborele are modificări necomise: un release corespunde unui commit."; exit 3; }
VER=$(grep -m1 'version = ' Sources/SadrogCore/AppInfo.swift | sed 's/.*"\(.*\)".*/\1/')
OUT="$EXT/dist/$VER"; mkdir -p "$OUT"
case "${1:-}" in
build)
  APP_BUILT=$("$ROOT/scripts/build_app.sh" | tail -1)
  rm -rf "$OUT/SADROG.app"; ditto "$APP_BUILT" "$OUT/SADROG.app"
  codesign --verify --deep --strict "$OUT/SADROG.app"
  echo "$OUT/SADROG.app" ;;
package)
  APP="$OUT/SADROG.app"; [ -d "$APP" ] || { echo "Rulează întâi: build"; exit 4; }
  DMG="$OUT/SADROG-$VER.dmg"; rm -f "$DMG"
  ditto -c -k --keepParent "$APP" "$OUT/SADROG-app.zip"
  xcrun notarytool submit "$OUT/SADROG-app.zip" --keychain-profile "$PROFILE" --wait | tee "$OUT/notary-app.log"
  grep -q "status: Accepted" "$OUT/notary-app.log" || { echo "Notarizarea aplicației a fost refuzată"; exit 5; }
  xcrun stapler staple "$APP"; rm -f "$OUT/SADROG-app.zip"
  STAGE="$OUT/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"; ditto "$APP" "$STAGE/SADROG.app"; ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "SADROG $VER" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG" >/dev/null; rm -rf "$STAGE"
  codesign --force --timestamp --sign "$ID" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait | tee "$OUT/notary-dmg.log"
  grep -q "status: Accepted" "$OUT/notary-dmg.log" || { echo "Notarizarea DMG a fost refuzată"; exit 6; }
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"; spctl -a -t open --context context:primary-signature -vv "$DMG"
  spctl -a -t exec -vv "$APP"; xcrun stapler validate "$APP"
  cp "$DMG" "$OUT/SADROG.dmg"                       # stable name for releases/latest/download/SADROG.dmg, next to the versioned one
  (cd "$OUT" && shasum -a 256 "SADROG-$VER.dmg" > "SADROG-$VER.dmg.sha256")
  echo "$DMG" ;;
*) echo "usage: $0 build|package"; exit 1 ;;
esac
