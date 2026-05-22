# Kiririn Plugin Spec

Kiririn の新しいプラグインは、WKWebExtension ベースの extension bundle として読み込まれます。
アプリ固有の機能は `window.kiririn` で公開し、標準の WebExtension API は WebKit が提供する実装を使います。

## 配布形式

- 配布用パッケージは `.kppx` です。
- `.kppx` は Valid な ZIP archive 形式ですが、配布用に署名されたものには Android APK Signature Scheme v2/v3 と同様に Central Directory の前領域に署名領域が存在します。
- Kiririn は `.kppx` archive の URL を `WKWebExtension` に渡して読み込みます。
- macOS の開発用途では、署名なしの local folder import も利用できます。

## ディレクトリ例

```text
MyPlugin/
  manifest.json
  panel.html
  overlay.html
  options.html
  assets/
```

## manifest.json

最小構成の例です。

```json
{
  "manifest_version": 3,
  "name": "Sample Plugin",
  "version": "1.0.0",
  "author": "Example Author",
  "homepage_url": "https://example.com/plugins/sample",
  "permissions": ["storage"],
  "host_permissions": ["https://api.example.com/*"],
  "browser_specific_settings": {
    "kiririn": {
      "id": "com.example.sample",
      "views": {
        "overlay": {
          "page": "overlay.html"
        },
        "panel": {
          "page": "panel.html"
        }
      },
      "update_url": "https://example.com/plugins/sample/update.json"
    }
  },
  "options_ui": {
    "page": "options.html"
  }
}
```

## 必須・主要フィールド

- `manifest_version`: 3
- `name`: プラグイン名
- `version`: バージョン文字列
- `browser_specific_settings.kiririn.id`: 一意性確認及びアップデート検出用ファイルでの使用する ID。この ID が重複したパッケージを同時に 2 つ以上導入することは出来ません。文字種は `A-Za-z0-9\.` が使用できます。逆順ドメインの形にしてください。
- `browser_specific_settings.kiririn.views.overlay.page`: プレイヤーオーバーレイ用ページ
- `browser_specific_settings.kiririn.views.panel.page`: パネル用ページ
- `options_ui.page`: 設定画面用ページ
- `browser_specific_settings.kiririn.update_url`: アップデート検出用ファイルの URL。定義は Firefox Addon のアップデート定義ファイルと同じフォーマットを利用する。
- `permissions`: 現状は `storage` のみ許可
- `host_permissions`: 外部通信先 URL パターン

少なくとも `browser_specific_settings.kiririn.views.overlay.page`、`browser_specific_settings.kiririn.views.panel.page`、`options_ui.page` のいずれか 1 つが必要です。

## 表示面

- `browser_specific_settings.kiririn.views.overlay.page`: プレイヤー上の overlay
- `browser_specific_settings.kiririn.views.panel.page`: プレイヤー下部に出る panel
- `options_ui.page`: プラグイン設定 UI

`window.kiririn.getRuntimeInfo().displayAreaType` の値は `overlay` / `panel` / `options` です。
`window.kiririn.getRuntimeInfo().playerID` は `overlay` のときだけ対応するプレイヤー ID を返し、`panel` / `options` では `null` を返します。

`panel` は Kiririn 固有の表示面です。`action.default_popup` は使用しません。

## 現在の制限

以下の manifest key はサポートしていません。

- `content_scripts`
- `commands`
- `action`
- `browser_action`
- `page_action`

## Bridge API

型定義は `KiririnPluginBridge.d.ts` にあります。

主要 API:

- `window.kiririn.getPlayables()`
- `window.kiririn.getPlayerStatuses()`
- `window.kiririn.getRuntimeInfo()`
- `window.kiririn.onOpenURL(...)`
- `window.kiririn.onCaptureTaken(...)`
- `window.kiririn.play()` / `pause()` / `togglePlayPause()` / `seek()`
- `window.kiririn.getCaptureBlob(...)`
- `window.kiririn.sendMessage(...)`

`onCaptureTaken(callback)` の payload は次のメタデータです。

```ts
{
  captureID: string;
  playerID: string;
  capturedAt: Date;
  variants: Array<{
    type: "original" | "composite";
    overlayPluginManifestIDs: string[];
  }>;
}
```

Blob の取得は `getCaptureBlob(captureID, variant)` を使います。`variant` は `"original"` または `"composite"` です。

Deep Link は次の形式です。

```text
kiririn://plugins/{browser_specific_settings.kiririn.id}?url={encoded url}
```

該当プラグインのページには `onOpenURL({ url })` が配送されます。

`getRuntimeInfo()` では次の情報を取得できます。

- `platform`: `iOS` または `macOS`
- `osVersion`: OS バージョン文字列
- `appVersion`: `CFBundleShortVersionString`
- `buildVersion`: `CFBundleVersion`
- `bundleIdentifier`: アプリの bundle identifier
- `bridgeVersion`: bridge schema のバージョン
- `displayAreaType`: `overlay` / `panel` / `options`
- `playerID`: `overlay` に紐づくプレイヤー ID。`panel` / `options` では `null`

## Import / Update

- `.kppx` ファイル import
- remote URL import
- macOS の local folder import
