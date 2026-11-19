#!/bin/zsh
# Builds Galley from source and installs it to /Applications (or ~/Applications if that is not writable).
set -e
cd "$(dirname "$0")/.."
command -v swift >/dev/null || { echo "Swift is missing: install Xcode or the Command Line Tools (xcode-select --install)."; exit 1; }
./make_app.sh
DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
osascript -e 'quit app "Galley"' 2>/dev/null || true
rm -rf "$DEST/Galley.app"
cp -R build/Galley.app "$DEST/"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/Galley.app"
echo "Installed $DEST/Galley.app"
if [ ! -x /Library/TeX/texbin/pdflatex ] && ! command -v tectonic >/dev/null; then
  echo
  echo "Galley needs TeX to typeset. Install one of:"
  echo "  brew install --cask mactex-no-gui     (full TeX Live)"
  echo "  brew install tectonic                 (small; fetches packages as needed)"
fi
open "$DEST/Galley.app"
