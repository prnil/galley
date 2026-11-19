#!/bin/zsh
# Builds a universal (Apple silicon + Intel) Galley.app and packs it as
# dist/Galley-<version>.dmg and .zip for a GitHub release.
set -e
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
UNIVERSAL=1 ./make_app.sh
rm -rf dist && mkdir -p dist/dmg
cp -R build/Galley.app dist/dmg/
ln -s /Applications dist/dmg/Applications
hdiutil create -volname "Galley $VERSION" -srcfolder dist/dmg -ov -format UDZO "dist/Galley-$VERSION.dmg" >/dev/null
(cd build && ditto -c -k --keepParent Galley.app "../dist/Galley-$VERSION.zip")
rm -rf dist/dmg
shasum -a 256 dist/*
