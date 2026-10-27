#!/bin/zsh
# Builds Relay.app into ~/Applications (Dock icon, Spotlight, its own mic/speech permissions).
set -e
cd "$(dirname "$0")"
swift build -c release
# The sidecar ships inside the app as one binary: no bun at runtime, and the install no longer follows this checkout.
# Built before the old app is removed, so a failed compile leaves the working install in place.
(cd sidecar && bun install --frozen-lockfile > /dev/null && bun build --compile index.ts --outfile ../.build/relay-sidecar > /dev/null)
APP="$HOME/Applications/Relay.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Relay "$APP/Contents/MacOS/Relay"
cp .build/relay-sidecar "$APP/Contents/MacOS/relay-sidecar"
codesign --force --sign - "$APP/Contents/MacOS/relay-sidecar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.png Resources/AppIcon-Dark.png "$APP/Contents/Resources/"
# Icon Composer icon: macOS shows the dark variant in Dark mode (Auto: from sunset to sunrise), even while Relay is closed.
xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 \
  --app-icon AppIcon --output-partial-info-plist /tmp/relay-icon.plist > /dev/null
# Dock tile plugin: swaps in the dark icon while Relay is closed (the "Default" icon style never does).
PLUG="$APP/Contents/PlugIns/RelayDock.docktileplugin/Contents"
mkdir -p "$PLUG/MacOS" "$PLUG/Resources"
swiftc -O -parse-as-library -emit-executable -Xlinker -bundle -module-name RelayDock -target arm64-apple-macos26.0 \
  DockTile/RelayDock.swift -o "$PLUG/MacOS/RelayDock"
cp DockTile/Info.plist "$PLUG/Info.plist"
cp Resources/AppIcon.png Resources/AppIcon-Dark.png "$PLUG/Resources/"
codesign --force --sign - "$APP/Contents/PlugIns/RelayDock.docktileplugin"
cp -R Resources/Logos "$APP/Contents/Resources/Logos"
cp Resources/excalidraw.html "$APP/Contents/Resources/"
codesign --force --sign - --identifier org.openrelay.relay "$APP"
# Re-register so the Dock picks up the new plugin and icon.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built $APP"
