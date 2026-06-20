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

# 既存の不完全な署名のクリーニング
rm -rf "$APP_BUNDLE/_CodeSignature" || true

# ネストされたフレームワーク等の署名
# バンドル内のすべてのフレームワークおよびダイナミックライブラリを探索し、個別に署名
# ただし、呼び出し元のセキュリティを引き継ぐため、Hardened Runtimeオプションは必須
if [ -d "$APP_BUNDLE/Contents/Frameworks" ]; then
    # Frameworkはディレクトリなので type d で探索して署名する
    find "$APP_BUNDLE/Contents/Frameworks" -type d -name "*.framework" | while read -r framework_dir; do
        echo "Signing embedded framework: $framework_dir"
        rm -rf "$framework_dir/_CodeSignature" || true
        /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
                          --options runtime \
                          --timestamp \
                          "$framework_dir"
    done

    # フレームワーク外に配置されるdylibも個別に署名する
    find "$APP_BUNDLE/Contents/Frameworks" -type f -name "*.dylib" | while read -r dylib_file; do
        echo "Signing embedded dylib: $dylib_file"
        /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
                          --options runtime \
                          --timestamp \
                          "$dylib_file"
    done
fi

# ヘルパーコマンドラインツールの署名
# ヘルパーが親アプリのSandbox環境を継承する場合、専用のentitlements（com.apple.security.inherit）を結合する
# HELPER_ENTITLEMENTS="kiririn/Helper.entitlements"
# if [ -d "$APP_BUNDLE/Contents/Helpers" ] && [ -f "$HELPER_ENTITLEMENTS" ]; then
#     find "$APP_BUNDLE/Contents/Helpers" -type f | while read -r helper_tool; do
#         echo "Signing helper tool: $helper_tool"
#         /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
#                           --options runtime \
#                           --entitlements "$HELPER_ENTITLEMENTS" \
#                           --timestamp \
#                           "$helper_tool"
#     done
# fi

# 本体の署名
echo "Signing main application bundle..."
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
                  --options runtime \
                  --entitlements "$ENTITLEMENTS" \
                  --timestamp \
                  "$APP_BUNDLE"

# 検証
codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"

echo "entitlements:"
codesign -d --entitlements :- "$APP_BUNDLE"

echo "Done"
