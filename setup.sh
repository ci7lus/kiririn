#!/usr/bin/env bash
set -euo pipefail

# https://github.com/neneka/vlckit/releases
REVISION="202606162330"
VLCKIT_URL="https://github.com/neneka/vlckit/releases/download/$REVISION/VLCKit-iOS-REPLACEWITHVERSION.dmg"
VLCKIT_DEST="./Packages/VLCKit"
FRAMEWORK_DEST="${VLCKIT_DEST}/VLCKit.xcframework"

rm -rf "$FRAMEWORK_DEST"

echo "Downloading VLCKit (DMG)..."
MOUNT_DIR=$(mktemp -d)

TEMP_DMG="tmp.dmg"
curl -sL "$VLCKIT_URL" -o "$TEMP_DMG"
echo "Mounting DMG...: $MOUNT_DIR"
hdiutil attach "$TEMP_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -quiet

echo "Extracting libraries from DMG..."
cp -R "$MOUNT_DIR/VLCKit.xcframework" "$FRAMEWORK_DEST"

hdiutil detach "$MOUNT_DIR" -quiet
rm -rf "$TEMP_DMG" "$MOUNT_DIR"

curl -sL "https://raw.githubusercontent.com/neneka/vlckit/refs/tags/$REVISION/COPYING" -o "$VLCKIT_DEST/VLCKitAssets/COPYING"

curl -sL "https://raw.githubusercontent.com/neneka/vlckit/refs/tags/$REVISION/share/hrtfs/dodeca_and_7channel_3DSL_HRTF.sofa" -o "$VLCKIT_DEST/VLCKitAssets/dodeca_and_7channel_3DSL_HRTF.sofa"
