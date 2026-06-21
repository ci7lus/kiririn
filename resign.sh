#!/usr/bin/env bash
set -euo pipefail

# --- パラメータの設定 ---
APP_BUNDLE="$1"
ENTITLEMENTS="kiririn/kiririn.entitlements"

if [ -z "${APP_BUNDLE:-}" ] || [ ! -d "$APP_BUNDLE" ]; then
    echo "Usage: SIGNING_IDENTITY='<Developer ID Application: ...>' ./resign.sh /path/to/App.app"
    exit 1
fi

if [ -z "${SIGNING_IDENTITY:-}" ]; then
    echo "ERROR: SIGNING_IDENTITY environment variable is not set"
    exit 1
fi

if [ -d "$APP_BUNDLE/Contents" ]; then
    PLATFORM="macos"
    FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
    #HELPERS_DIR="$APP_BUNDLE/Contents/Helpers"
    PLUGINS_DIR="$APP_BUNDLE/Contents/PlugIns"
else
    PLATFORM="ios"
    FRAMEWORKS_DIR="$APP_BUNDLE/Frameworks"
    #HELPERS_DIR="$APP_BUNDLE/Helpers"
    PLUGINS_DIR="$APP_BUNDLE/PlugIns"
fi

sign_embedded_code() {
    local target_path="$1"

    rm -rf "$target_path/_CodeSignature" || true

    if [ "$PLATFORM" = "macos" ]; then
        /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
                          --options runtime \
                          --timestamp \
                          "$target_path"
    else
        /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
                          "$target_path"
    fi
}

# 既存の不完全な署名のクリーニング
rm -rf "$APP_BUNDLE/_CodeSignature" || true

# ネストされたbundleの署名
find "$APP_BUNDLE" -depth -type d -name "*.bundle" | while read -r bundle_dir; do
    echo "Signing embedded bundle: $bundle_dir"
    sign_embedded_code "$bundle_dir"
done

# ネストされたフレームワーク等の署名
if [ -d "$FRAMEWORKS_DIR" ]; then
    # フレームワーク外に配置されるdylibも個別に署名する
    find "$FRAMEWORKS_DIR" -type f -name "*.dylib" | while read -r dylib_file; do
        echo "Signing embedded dylib: $dylib_file"
        sign_embedded_code "$dylib_file"
    done

    # Frameworkはディレクトリなので type d で探索して署名する
    find "$FRAMEWORKS_DIR" -depth -type d -name "*.framework" | while read -r framework_dir; do
        echo "Signing embedded framework: $framework_dir"
        sign_embedded_code "$framework_dir"
    done
fi

# App Extensionやプラグインの署名
if [ -d "$PLUGINS_DIR" ]; then
    find "$PLUGINS_DIR" -depth \( -type d -name "*.appex" -o -type d -name "*.bundle" \) | while read -r plugin_dir; do
        echo "Signing embedded plugin: $plugin_dir"
        sign_embedded_code "$plugin_dir"
    done
fi

# ヘルパーコマンドラインツールの署名
# ヘルパーが親アプリのSandbox環境を継承する場合、専用のentitlements（com.apple.security.inherit）を結合する
# HELPER_ENTITLEMENTS="kiririn/Helper.entitlements"
# if [ -d "$HELPERS_DIR" ] && [ -f "$HELPER_ENTITLEMENTS" ]; then
#     find "$HELPERS_DIR" -type f | while read -r helper_tool; do
#         echo "Signing helper tool: $helper_tool"
#         if [ "$PLATFORM" = "macos" ]; then
#             /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
#                               --options runtime \
#                               --entitlements "$HELPER_ENTITLEMENTS" \
#                               --timestamp \
#                               "$helper_tool"
#         else
#             /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
#                               --entitlements "$HELPER_ENTITLEMENTS" \
#                               "$helper_tool"
#         fi
#     done
# fi

# 本体の署名
echo "Signing main application bundle..."
if [ "$PLATFORM" = "macos" ]; then
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
                      --options runtime \
                      --entitlements "$ENTITLEMENTS" \
                      --timestamp \
                      "$APP_BUNDLE"
else
    /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
                      --entitlements "$ENTITLEMENTS" \
                      "$APP_BUNDLE"
fi

# 検証
codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"

echo "entitlements:"
codesign -d --entitlements :- "$APP_BUNDLE"

echo "Done"
