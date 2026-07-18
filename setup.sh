#!/usr/bin/env bash
set -euo pipefail

# VLCKit
# https://github.com/neneka/vlckit/releases
REVISION="202607180216"
VLCKIT_URL="https://github.com/neneka/vlckit/releases/download/$REVISION/VLCKit-iOS-REPLACEWITHVERSION.dmg"
VLCKIT_DEST="./Packages/VLCKit"
FRAMEWORK_DEST="${VLCKIT_DEST}/VLCKit.xcframework"
LICENSE_NOTICES_DEST="${VLCKIT_DEST}/VLCKitAssets/LicenseNotices"

if [ "${VLCKIT_CACHE_HIT:-}" = "true" ]; then
  echo "VLCKit cache hit"
else
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
fi

# BML (データ放送) Webバンドル
echo "Building BML web bundle..."
git submodule update --init --force web/web-bml
if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required to build the BML web bundle (see web/bml)." >&2
  exit 1
fi
(cd web/bml && npm ci && npm run build)
BML_DEST="kiririn/Features/Player/DataBroadcast/Web/dist"
rm -rf "$BML_DEST"
mkdir -p "$(dirname "$BML_DEST")"
cp -R web/bml/dist "$BML_DEST"
