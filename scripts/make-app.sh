#!/bin/bash
# Build ModelBar and assemble a .app bundle by hand.
#
# There is no Xcode on this machine (CommandLineTools only), so there is no
# xcodebuild and no .xcodeproj — SwiftPM produces a bare executable and this
# script wraps it in the bundle layout macOS needs.
#
# Usage: scripts/make-app.sh [install]
#   install → also copy the bundle to /Applications

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ModelBar"
BUILD_DIR="$REPO/.build/release"
APP="$REPO/build/$APP_NAME.app"

echo "==> building (release)"
cd "$REPO"
swift build -c release

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# LSUIElement=true is what makes this a menubar-only app: no Dock icon, no
# menu bar of its own, no window on launch.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>ModelBar</string>
    <key>CFBundleDisplayName</key>          <string>ModelBar</string>
    <key>CFBundleIdentifier</key>           <string>com.sj.modelbar</string>
    <key>CFBundleExecutable</key>           <string>ModelBar</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>1.0</string>
    <key>CFBundleVersion</key>              <string>1</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key>       <string>26.0</string>
    <key>LSUIElement</key>                  <true/>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key>  <false/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature. arm64 binaries must be signed to run; the linker already
# applies one to the executable, but the bundle needs its own so that
# SMAppService (launch-at-login) has a stable identity to register.
echo "==> signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> built $APP"

if [ "${1:-}" = "install" ]; then
    DEST="/Applications/$APP_NAME.app"
    echo "==> installing to $DEST"
    # Quit any running copy first, or the copy lands under a running binary.
    osascript -e 'tell application "ModelBar" to quit' 2>/dev/null || true
    pkill -x ModelBar 2>/dev/null || true
    sleep 1
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    echo "==> installed. launch with: open -a ModelBar"
fi
