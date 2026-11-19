#!/bin/zsh
# Builds build/Galley.app. Pass --install to copy it to /Applications.
set -e
cd "$(dirname "$0")"
# UNIVERSAL=1 builds for Apple silicon and Intel (used for releases).
if [[ -n "$UNIVERSAL" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Galley"
else
  swift build -c release
  BIN=.build/release/Galley
fi
APP=build/Galley.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
# The Looseleaf look: Kevin Sans + IBM Plex Mono and the paper tiles. Licences travel with them.
cp -R Resources/Fonts Resources/Paper "$APP/Contents/Resources/"
[ -d Resources/Templates ] && cp -R Resources/Templates "$APP/Contents/Resources/"
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 14.0 --output-partial-info-plist build/assets-info.plist >/dev/null
[ -f Resources/Galley.icns ] && cp Resources/Galley.icns "$APP/Contents/Resources/" && /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string Galley" "$APP/Contents/Info.plist" 2>/dev/null || true
# Fixed designated requirement, so every ad-hoc build counts as the same app (Open Recent survives).
codesign --force --sign - -r='designated => identifier "io.github.pranil-sekuru.galley"' "$APP"
echo "Built $APP"
if [[ "$1" == "--install" ]]; then
  rm -rf /Applications/Galley.app && cp -R "$APP" /Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Galley.app
  echo "Installed /Applications/Galley.app"
fi
