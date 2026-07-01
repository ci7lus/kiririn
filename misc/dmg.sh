#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE_INPUT="${1:-}"
DMG_OUTPUT_INPUT="${2:-}"

usage() {
    echo "Usage: SIGNING_IDENTITY_DMG='<Developer ID Application: ...>' NOTARYTOOL_PROFILE='<profile>' ./dmg.sh /path/to/App.app [output.dmg]"
}

if [ -z "$APP_BUNDLE_INPUT" ] || [ ! -d "$APP_BUNDLE_INPUT" ]; then
    usage
    exit 1
fi

if [ "${APP_BUNDLE_INPUT##*.}" != "app" ]; then
    echo "ERROR: input path must be an .app bundle"
    usage
    exit 1
fi

if [ -z "${SIGNING_IDENTITY_DMG:-}" ]; then
    echo "ERROR: SIGNING_IDENTITY_DMG environment variable is not set"
    exit 1
fi

if [ -z "${NOTARYTOOL_PROFILE:-}" ]; then
    echo "ERROR: NOTARYTOOL_PROFILE environment variable is not set"
    exit 1
fi

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "ERROR: create-dmg is not installed"
    exit 1
fi

if ! xcrun --find notarytool >/dev/null 2>&1; then
    echo "ERROR: notarytool is not installed"
    exit 1
fi

if ! xcrun --find stapler >/dev/null 2>&1; then
    echo "ERROR: stapler is not installed"
    exit 1
fi

APP_BUNDLE_DIR="$(cd "$(dirname "$APP_BUNDLE_INPUT")" && pwd -P)"
APP_BUNDLE_NAME="$(basename "$APP_BUNDLE_INPUT")"
APP_BUNDLE="$APP_BUNDLE_DIR/$APP_BUNDLE_NAME"
APP_NAME="${APP_BUNDLE_NAME%.app}"

if [ -n "$DMG_OUTPUT_INPUT" ]; then
    DMG_OUTPUT_DIR="$(cd "$(dirname "$DMG_OUTPUT_INPUT")" && pwd -P)"
    DMG_OUTPUT="$DMG_OUTPUT_DIR/$(basename "$DMG_OUTPUT_INPUT")"
else
    DMG_OUTPUT="$APP_BUNDLE_DIR/$APP_NAME.dmg"
fi

if [ "${DMG_OUTPUT##*.}" != "dmg" ]; then
    echo "ERROR: output path must end with .dmg"
    usage
    exit 1
fi

if [ -e "$DMG_OUTPUT" ]; then
    echo "ERROR: output DMG already exists: $DMG_OUTPUT"
    exit 1
fi

TMP_DIR="$(mktemp -d)"
STAGING_DIR="$TMP_DIR/staging"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$STAGING_DIR"
ditto "$APP_BUNDLE" "$STAGING_DIR/$APP_BUNDLE_NAME"

echo "Creating DMG: $DMG_OUTPUT"
create-dmg \
    --volname "$APP_NAME" \
    --window-pos 200 120 \
    --window-size 640 360 \
    --icon-size 100 \
    --icon "$APP_BUNDLE_NAME" 180 170 \
    --hide-extension "$APP_BUNDLE_NAME" \
    --app-drop-link 460 170 \
    --no-internet-enable \
    --skip-jenkins \
    "$DMG_OUTPUT" \
    "$STAGING_DIR"

echo "Signing DMG..."
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY_DMG" --timestamp "$DMG_OUTPUT"

echo "Verifying DMG signature..."
/usr/bin/codesign --verify -dvvv "$DMG_OUTPUT"

echo "Notarizing DMG..."
xcrun notarytool submit "$DMG_OUTPUT" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait

echo "Stapling notarization ticket..."
xcrun stapler staple "$DMG_OUTPUT"

echo "Validating notarization ticket..."
xcrun stapler validate "$DMG_OUTPUT"

echo "Verifying DMG signature and notarization..."
spctl -a -t open --context context:primary-signature -v "$DMG_OUTPUT"

echo "Done: $DMG_OUTPUT"
