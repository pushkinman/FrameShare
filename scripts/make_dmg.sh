#!/bin/bash
# FrameShare — by Anton Pushkin
# Builds a universal FrameShare.app and packs it into build/FrameShare-<version>.dmg
# for installing on another Mac (drag to Applications).
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=1 ./scripts/build_app.sh

VERSION=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
STAGE="build/dmg"
DMG="build/FrameShare-$VERSION.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/FrameShare.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<'TXT'
FrameShare — developed by Anton Pushkin

INSTALL
1. Drag FrameShare onto the Applications folder.
2. Open FrameShare from Applications.
   macOS will say it can't verify the app (it's a personal build, not from the App Store).
   Click "Done", then go to System Settings → Privacy & Security, scroll down,
   and click "Open Anyway" next to FrameShare. Confirm once; after that it opens normally.
   (Terminal alternative: xattr -dr com.apple.quarantine /Applications/FrameShare.app)
3. Click the dashed-rectangle icon in the menu bar → Start Sharing.
   Allow Screen Recording when asked, then quit and reopen FrameShare.

Needs macOS 14 Sonoma or newer. Works on Apple Silicon and Intel Macs.
TXT

hdiutil create -volname "FrameShare" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
rm -rf "$STAGE"
hdiutil verify "$DMG" >/dev/null && echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
