#!/bin/bash
# FrameShare — by Anton Pushkin
# Builds FrameShare.app into ./build. With --install, copies it to ~/Applications and opens it.
# Signs with "FrameShare Local Signing" if scripts/setup_signing.sh was run, otherwise ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/FrameShare.app"
mkdir -p build
if [ "${UNIVERSAL:-0}" = "1" ]; then
  # One app that runs on both Apple Silicon and Intel Macs.
  for ARCH in arm64 x86_64; do
    swift build -c release --triple "$ARCH-apple-macosx14.0" --scratch-path ".build/$ARCH"
    cp "$(swift build -c release --triple "$ARCH-apple-macosx14.0" --scratch-path ".build/$ARCH" --show-bin-path)/FrameShare" "build/FrameShare-$ARCH"
  done
  lipo -create -output build/FrameShare-universal build/FrameShare-arm64 build/FrameShare-x86_64
  BIN="build/FrameShare-universal"
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/FrameShare"
fi

if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make_icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FrameShare"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Use the stable local certificate if it exists (see scripts/setup_signing.sh), else ad-hoc.
if [ -z "${SIGN_IDENTITY:-}" ] && security find-certificate -c "FrameShare Local Signing" >/dev/null 2>&1; then
  SIGN_IDENTITY="FrameShare Local Signing"
fi
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier local.frameshare.app "$APP"
echo "Signed with: ${SIGN_IDENTITY:-ad-hoc (permissions reset on every rebuild)}"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x FrameShare 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/FrameShare.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "Installed to ~/Applications/FrameShare.app"
  open "$HOME/Applications/FrameShare.app"
fi
