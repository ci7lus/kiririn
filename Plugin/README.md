# kiririn Plugin Spec

kiririn の新しいプラグインは、WKWebExtension ベースの extension bundle として読み込まれます。
アプリ固有の機能は `window.kiririn` で公開し、標準の WebExtension API は WebKit が提供する実装を使います。

## 配布形式

- 配布用パッケージは `.kppx` です。
- `.kppx` は Valid な ZIP archive 形式ですが、配布用に署名されたものには Android APK Signature Scheme v2 / v3 / v3.1 と同様に Central Directory の前領域に署名領域が存在します。
- kiririn は `.kppx` archive の URL を `WKWebExtension` に渡して読み込みます。
- macOS の開発用途では、署名なしの local folder import も利用できます。
- 署名付き package は同梱の PKI (`trusted_chain.pem`) で検証されます。
- 開発者モードを有効にすると未署名・自己署名のパッケージも追加できます。

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
- `browser_specific_settings.kiririn.strict_min_version`: このプラグインが要求する kiririn の最小バージョン。任意。
- `browser_specific_settings.kiririn.strict_max_version`: このプラグインが対応する kiririn の最大バージョン。任意。`*` も利用可能。
- `permissions`: 現状は `storage` のみ許可
- `host_permissions`: 外部通信先 URL パターン

少なくとも `browser_specific_settings.kiririn.views.overlay.page`、`browser_specific_settings.kiririn.views.panel.page`、`options_ui.page` のいずれか 1 つが必要です。

`strict_min_version` / `strict_max_version` の判定はアプリの `CFBundleShortVersionString` と数値比較で行います。
通常モードでは互換性を満たさないプラグインは追加・更新できません。
開発者モードでは警告を表示したうえで追加・更新できます。

## 表示面

- `browser_specific_settings.kiririn.views.overlay.page`: プレイヤー上の overlay
- `browser_specific_settings.kiririn.views.panel.page`: プレイヤー下部に出る panel
- `options_ui.page`: プラグイン設定 UI

`window.kiririn.getRuntimeInfo().displayAreaType` の値は `overlay` / `panel` / `options` です。
`window.kiririn.getRuntimeInfo().playerID` は `overlay` のときだけ対応するプレイヤー ID を返し、`panel` / `options` では `null` を返します。

`panel` は kiririn 固有の表示面です。`action.default_popup` は使用しません。

## 現在の制限

以下の manifest key はサポートしていません。

- `content_scripts`
- `commands`
- `action`
- `browser_action`
- `page_action`

## Bridge API

型定義は `kiririnPluginBridge.d.ts` にあります。

主要 API:

- `window.kiririn.getPlayables()`
- `window.kiririn.getPlayerStatuses()`
- `window.kiririn.getRuntimeInfo()`
- `window.kiririn.onDeeplinkOpened(...)`
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
kiririn://plugins/{browser_specific_settings.kiririn.id}
```

該当プラグインのページには Deep Link URL 全体が `onDeeplinkOpened({ url })` として配送されます。

`getRuntimeInfo()` では次の情報を取得できます。

- `platform`: `iOS` または `macOS`
- `osVersion`: OS バージョン文字列
- `appVersion`: `CFBundleShortVersionString`
- `buildVersion`: `CFBundleVersion`
- `bundleIdentifier`: アプリの bundle identifier
- `bridgeVersion`: bridge schema のバージョン
- `displayAreaType`: `overlay` / `panel` / `options`
- `playerID`: `overlay` に紐づくプレイヤー ID。`panel` / `options` では `null`

Bridge は表示領域でUIと重ならないための余白(px相当)を CSS カスタムプロパティとして自動注入します。

- `--kiririn-safe-area-inset-top`
- `--kiririn-safe-area-inset-right`
- `--kiririn-safe-area-inset-bottom`
- `--kiririn-safe-area-inset-left`

`env(safe-area-inset-*)` 自体は上書きできないため、必要に応じて次のように合算してください。

```css
padding-bottom: calc(env(safe-area-inset-bottom) + var(--kiririn-safe-area-inset-bottom, 0px));
```

## Import / Update

- `.kppx` ファイル/URL import
- macOS の local folder import
- `update_url` による手動アップデートは、インストール済み package と更新先 package の両方が署名付きであり、Leaf 証明書の公開鍵 (SPKI SHA-256) が一致する場合のみ利用できます。
- 未署名 package は `update_url` を定義していてもアップデート操作を利用できません。
- 自動アップデートはありません。署名付き `.kppx` で導入されたプラグインだけが詳細画面で「アップデートを確認する」を表示します。

`update_url` の update manifest では以下をサポートします。

- `update_link`: `https` または `http`。`http` の場合は `update_hash` が必須。
- `update_hash`: 任意。`sha256:` または `sha512:` で始まる形式を受け付けます。指定された場合は `https` でも必ず検証し、不一致なら更新を中止します。
- `update_info_url`: 任意。アップデート完了後の sheet から開けます。
- `applications.gecko`: 任意。省略時は互換とみなします。指定する場合は `gecko` を含めてください。
- `applications.gecko.strict_min_version` / `strict_max_version`: アプリの `CFBundleShortVersionString` と照合し、互換性がある更新候補だけを対象にします。

更新候補は `version` の数値比較で降順に選定します。
