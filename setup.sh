#!/usr/bin/env bash
set -euo pipefail

# VLCKit
# https://github.com/neneka/vlckit/releases
REVISION="202607110626"
VLCKIT_URL="https://github.com/neneka/vlckit/releases/download/$REVISION/VLCKit-iOS-REPLACEWITHVERSION.dmg"
VLCKIT_DEST="./Packages/VLCKit"
FRAMEWORK_DEST="${VLCKIT_DEST}/VLCKit.xcframework"
LICENSE_NOTICES_DEST="${VLCKIT_DEST}/VLCKitAssets/LicenseNotices"

rm -rf "$FRAMEWORK_DEST"
rm -rf "$LICENSE_NOTICES_DEST"

echo "Downloading VLCKit (DMG)..."
MOUNT_DIR=$(mktemp -d)

TEMP_DMG="tmp.dmg"
curl -sL "$VLCKIT_URL" -o "$TEMP_DMG"
echo "Mounting DMG...: $MOUNT_DIR"
hdiutil attach "$TEMP_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -quiet

echo "Extracting libraries from DMG..."
cp -R "$MOUNT_DIR/VLCKit.xcframework" "$FRAMEWORK_DEST"

echo "Extracting VLCKit license notices from DMG..."
mkdir -p "$LICENSE_NOTICES_DEST"
cp "$MOUNT_DIR/License Notices/licenses/"*.txt "$LICENSE_NOTICES_DEST"

hdiutil detach "$MOUNT_DIR" -quiet
rm -rf "$TEMP_DMG" "$MOUNT_DIR"

curl -sL "https://raw.githubusercontent.com/neneka/vlckit/refs/tags/$REVISION/share/hrtfs/dodeca_and_7channel_3DSL_HRTF.sofa" -o "$VLCKIT_DEST/VLCKitAssets/dodeca_and_7channel_3DSL_HRTF.sofa"

# Rounded M+ 1m WadaLab mix ARIB
curl -sL "https://github.com/vivid-lapin/rounded-mplus-wadalab-mix/releases/download/202606272034/rounded-mplus-1m-wadalab-comp-arib.ttf" -o "kiririn/rounded-mplus-1m-wadalab-comp-arib.ttf"
