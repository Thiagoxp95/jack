#!/usr/bin/env bash
set -euo pipefail

# Usage: ./Scripts/make_dmg.sh [path-to-app]
#
# After archiving in Xcode:
#   1. Organizer → select archive → "Distribute App" → "Copy App" → save to a folder
#   2. Run: ./Scripts/make_dmg.sh /path/to/exported/JackApp.app
#
# Or without arguments, it uses the most recent Xcode archive automatically.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME="JackApp"
DMG_NAME="Jack"

if [[ -f "$ROOT/version.env" ]]; then
  source "$ROOT/version.env"
else
  MARKETING_VERSION=${MARKETING_VERSION:-0.1.0}
fi

# Find the .app to package
if [[ ${1:-} != "" ]]; then
  APP_PATH="$1"
elif [[ -d "$ROOT/${APP_NAME}.app" ]]; then
  APP_PATH="$ROOT/${APP_NAME}.app"
else
  # Try to find the most recent Xcode archive and extract the app
  ARCHIVES_DIR="$HOME/Library/Developer/Xcode/Archives"
  if [[ -d "$ARCHIVES_DIR" ]]; then
    LATEST_ARCHIVE=$(find "$ARCHIVES_DIR" -name "*.xcarchive" -maxdepth 2 | sort -r | head -1)
    if [[ -n "$LATEST_ARCHIVE" ]]; then
      APP_PATH="$LATEST_ARCHIVE/Products/Applications/${APP_NAME}.app"
      echo "Using app from archive: $LATEST_ARCHIVE"
    fi
  fi
fi

if [[ -z "${APP_PATH:-}" || ! -d "$APP_PATH" ]]; then
  echo "ERROR: No .app found. Either:"
  echo "  1. Pass the path: $0 /path/to/JackApp.app"
  echo "  2. Archive in Xcode first, then run without arguments"
  exit 1
fi

echo "Packaging: $APP_PATH"

DMG_PATH="$ROOT/${DMG_NAME}-${MARKETING_VERSION}.dmg"
STAGING="$ROOT/.build/dmg-staging"

rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"

# Copy .app into staging
cp -R "$APP_PATH" "$STAGING/"

# Create a symlink to /Applications for drag-and-drop install
ln -s /Applications "$STAGING/Applications"

# Create the DMG
hdiutil create \
  -volname "$DMG_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$STAGING"

echo ""
echo "DMG created: $DMG_PATH"
echo "Size: $(du -h "$DMG_PATH" | cut -f1)"
