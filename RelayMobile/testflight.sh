#!/bin/zsh
# Archives Relay for iPhone and uploads it to App Store Connect, where it shows up in TestFlight.
# Needs: the paid Apple Developer Program on your team, Xcode signed in to that account,
# and an app record in App Store Connect for org.openrelay.relay.mobile (see README.md).
set -e
cd "$(dirname "$0")"
xcodegen generate
BUILD=$(date +%y%m%d%H%M)
rm -rf build/Relay.xcarchive build/export
xcodebuild -project RelayMobile.xcodeproj -scheme Relay -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/Relay.xcarchive -allowProvisioningUpdates CURRENT_PROJECT_VERSION=$BUILD archive
xcodebuild -exportArchive -archivePath build/Relay.xcarchive -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export -allowProvisioningUpdates
echo "Uploaded build $BUILD. It appears in TestFlight once App Store Connect finishes processing (usually 5–15 minutes)."
