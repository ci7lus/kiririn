#!/usr/bin/env bash
set -euo pipefail

# VLCKit
# https://github.com/neneka/vlckit/releases
REVISION="202609020405"
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

fi

curl -sL "https://raw.githubusercontent.com/neneka/vlckit/refs/tags/$REVISION/share/hrtfs/dodeca_and_7channel_3DSL_HRTF.sofa" -o "$VLCKIT_DEST/VLCKitAssets/dodeca_and_7channel_3DSL_HRTF.sofa"

# Rounded M+ 1m WadaLab mix ARIB
curl -sL "https://github.com/vivid-lapin/rounded-mplus-wadalab-mix/releases/download/202606272034/rounded-mplus-1m-wadalab-comp-arib.ttf" -o "kiririn/rounded-mplus-1m-wadalab-comp-arib.ttf"

(
  SOURCE_HAN_VERSION="2.005R"
  SOURCE_HAN_BASE_URL="https://raw.githubusercontent.com/adobe-fonts/source-han-sans/${SOURCE_HAN_VERSION}"
  SOURCE_HAN_FONT_SHA256="23b20a0139e03981496b6e66bcb14263a517fd94624918289b8b988789a34a01"
  SOURCE_HAN_LICENSE_SHA256="fcac737e761ec63dbfbdce11030a1780161920d80315edba9c8beff1c2bac5a2"
  SOURCE_HAN_TEMP_DIR=$(mktemp -d)
  trap 'rm -rf "$SOURCE_HAN_TEMP_DIR"' EXIT

  echo "Downloading Source Han Sans ${SOURCE_HAN_VERSION}..."
  curl -fLsS "$SOURCE_HAN_BASE_URL/Variable/TTF/SourceHanSans-VF.ttf" -o "$SOURCE_HAN_TEMP_DIR/SourceHanSans-VF.ttf"
  curl -fLsS "$SOURCE_HAN_BASE_URL/LICENSE.txt" -o "$SOURCE_HAN_TEMP_DIR/SourceHanSans-LICENSE.txt"
  printf '%s  %s\n' "$SOURCE_HAN_FONT_SHA256" "$SOURCE_HAN_TEMP_DIR/SourceHanSans-VF.ttf" | shasum -a 256 -c -
  printf '%s  %s\n' "$SOURCE_HAN_LICENSE_SHA256" "$SOURCE_HAN_TEMP_DIR/SourceHanSans-LICENSE.txt" | shasum -a 256 -c -
  cp "$SOURCE_HAN_TEMP_DIR/SourceHanSans-VF.ttf" "kiririn/SourceHanSans-VF.ttf"
  cp "$SOURCE_HAN_TEMP_DIR/SourceHanSans-LICENSE.txt" "kiririn/SourceHanSans-LICENSE.txt"
  rm -f kiririn/argk-VF.ttf kiririn/argk-OFL.txt kiririn/argk-SourceHanSans-LICENSE.txt
)

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
