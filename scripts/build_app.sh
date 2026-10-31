#!/bin/bash
# Builds SADROG.app into the external build folder and signs it. Usage: scripts/build_app.sh [identity]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT="${SADROG_BUILD_DIR:-$HOME/sadrog-build}"
mkdir -p "$EXT" 2>/dev/null; [ -w "$EXT" ] || { echo "Build folder not writable: set SADROG_BUILD_DIR"; exit 2; }
ID="${1:-Developer ID Application: DUMITRU CRISTINEL GORDAS (8AR6XP8MG7)}"
VER=$(grep -m1 'version = ' "$ROOT/Sources/SadrogCore/AppInfo.swift" | sed 's/.*"\(.*\)".*/\1/')
cd "$ROOT"
BUILD=$(git rev-list --count HEAD)
SRC=$(git rev-parse --short HEAD)$( [ -n "$(git status --porcelain)" ] && echo "+modificări" || true )
BDATE=$(date "+%Y-%m-%d %H:%M")
TMPDIR="$EXT/temp" swift build -c release --scratch-path "$EXT/builds/sadrog"
APP="$EXT/builds/SADROG-$VER.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$EXT/builds/sadrog/release/Sadrog" "$APP/Contents/MacOS/SADROG"
# app icon, drawn from the approved vector mark (scripts/icon) → AppIcon.icns
ICON="$EXT/builds/icon"; mkdir -p "$ICON" "$APP/Contents/Resources"
TMPDIR="$EXT/temp" swiftc -O -suppress-warnings -module-cache-path "$EXT/temp/modcache" -module-name MakeIcon \
  "$ROOT/Sources/Sadrog/Design/LogoData.swift" "$ROOT/Sources/Sadrog/Design/LogoMark.swift" "$ROOT/scripts/icon/main.swift" -o "$ICON/MakeIcon"
"$ICON/MakeIcon" "$ICON/icon_1024.png"
rm -rf "$ICON/AppIcon.iconset"; mkdir "$ICON/AppIcon.iconset"
for sz in 16 32 128 256 512; do
  sips -z $sz $sz "$ICON/icon_1024.png" --out "$ICON/AppIcon.iconset/icon_${sz}x${sz}.png" >/dev/null
  sips -z $((sz*2)) $((sz*2)) "$ICON/icon_1024.png" --out "$ICON/AppIcon.iconset/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICON/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>ro</string><string>en</string><string>es</string></array>
<key>CFBundleExecutable</key><string>SADROG</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>dev.gordas.sadrog</string>
<key>CFBundleName</key><string>SADROG</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VER</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>SADROGSourceID</key><string>$SRC</string>
<key>SADROGBuildDate</key><string>$BDATE</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSCameraUsageDescription</key><string>SADROG înregistrează camera aleasă de tine, într-un fișier separat, doar cât timp înregistrezi.</string>
<key>NSMicrophoneUsageDescription</key><string>SADROG folosește microfonul și intrările audio alese de tine doar pentru nivelul afișat și pentru înregistrare, când le pornești explicit.</string>
</dict></plist>
PL
for l in ro en es; do mkdir -p "$APP/Contents/Resources/$l.lproj"; cp "$ROOT/Localization/InfoPlist/$l.strings" "$APP/Contents/Resources/$l.lproj/InfoPlist.strings"; done
cat > "$EXT/builds/sadrog.entitlements" <<EN
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/><key>com.apple.security.device.camera</key><true/></dict></plist>
EN
codesign --force --options runtime --timestamp --entitlements "$EXT/builds/sadrog.entitlements" --sign "$ID" "$APP"
echo "$APP"
echo "versiune $VER · build $BUILD · sursa $SRC" >&2
