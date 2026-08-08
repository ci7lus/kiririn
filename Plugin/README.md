# kiririn v0.3.0 プラグイン仕様

<!-- SPDX-License-Identifier: Apache-2.0 -->

kiririnのプラグインは、WebKitのWebExtensionを基盤にしています。プラグイン固有の機能は`window.kiririn`で提供し、それ以外はWebKitが実装するWebExtension APIを利用します。

以下は、リポジトリ内の現在の実装に沿った仕様です。WebExtension APIの細かな対応は、OSとWebKitのバージョンで変わります。

- 型定義: [KiririnPluginBridge.d.ts](./KiririnPluginBridge.d.ts)
- サンプル実装: [ci7lus/kiririn-plugins](https://github.com/ci7lus/kiririn-plugins)

## 最小構成

プラグインは、ルートに`manifest.json`を置いたディレクトリとして作成します。

```text
MyPlugin/
├── manifest.json
├── overlay.html
├── panel.html
├── options.html
├── background.js
└── assets/
    ├── app.js
    └── style.css
```

オーバーレイ、パネル、設定画面のどれか1つを実装すれば、プラグインとして読み込めます。使わないページとmanifest keyは省略してください。

オーバーレイだけなら、manifestの最小構成は以下のようになります。

```json
{
  "manifest_version": 3,
  "name": "Sample Plugin",
  "version": "1.0.0",
  "browser_specific_settings": {
    "kiririn": {
      "id": "com.example.sample",
      "views": {
        "overlay": {
          "page": "overlay.html"
        }
      }
    }
  }
}
```

`manifest_version`には`3`を指定してください。

## 実行モデル

プラグインの各ページは、プラグインごとに分離されたWebExtensionコンテキストとWebViewで実行されます。プラグイン間でストレージやBridgeの状態を共有することはできません。

### 表示領域

| manifest | 表示場所 | `getRuntimeInfo().displayAreaType` | `getRuntimeInfo().playerID` |
| --- | --- | --- | --- |
| `browser_specific_settings.kiririn.views.overlay.page` | プレイヤー上のオーバーレイ。プレイヤーごとに表示されます | `overlay` | 対象プレイヤーのID |
| `browser_specific_settings.kiririn.views.panel.page` | プレイヤー下部のパネル。macOSでは独立したプラグインウィンドウとしても表示されます | `panel` | `null` |
| `options_ui.page` | プラグイン設定画面 | `options` | `null` |

`playerID`が`null`でも、iOSのパネルは内部で表示中のプレイヤーに紐付いている場合があります。再生操作の対象を固定したいときは、`getPlayables()`などで得た`playerID`をメソッドに渡してください。

オーバーレイはプレイヤー映像の上に重なります。当たり判定がない状態で表示するため、クリックやタップを受け取りません。操作UIにはパネルか設定画面を使ってください。

オーバーレイはプレイヤーの表示領域全体に配置されます。データ放送などによって実際のテレビ画面や映像が一部の領域に表示される場合は、Bridgeの`televisionDisplayRect`と`videoDisplayRect`を使って位置を合わせます。

WebViewの背景は透明になります。オーバーレイのHTMLでは、映像を隠さないようにページ全体へ不透明な背景色を設定しないでください。iOSではオーバーレイのスクロールも無効です。パネルと設定画面は通常のスクロール領域として扱われます。

backgroundを持つプラグインは、表示ページが閉じている間もWebExtensionランタイムが保持されます。backgroundがないプラグインは、表示中のWebViewがなくなるとランタイムが破棄されることがあります。

### ストレージとWebExtension API

`permissions`と`host_permissions`は、現在の実装では表示時に自動で許可されます。ユーザーへの確認ダイアログは出ません。

利用できる標準権限は2つです。

- `storage`
- `unlimitedStorage`

その他の値を`permissions`に指定するとmanifest検証で拒否されます。`host_permissions`はWebExtensionのmatch patternとしてWebKitが解釈できる形式を指定してください。外部APIへ`fetch`する場合などに利用します。

プラグインのストレージはプラグインごとに分離されます。`browser_specific_settings.kiririn.id`を変更すると別プラグインとして扱われ、既存プラグインの更新にはなりません。

プラグインを削除すると、そのプラグインに紐付いたWebExtensionデータとWebサイトデータも削除されます。設定画面からストレージを消去した場合も、対象プラグインのデータを消去してから再読み込みします。

## manifest.json

### 例

```json
{
  "manifest_version": 3,
  "name": "Sample Plugin",
  "version": "1.2.0",
  "author": "Example Author",
  "description": "kiririn用のサンプルプラグインです。",
  "homepage_url": "https://example.com/plugins/sample",
  "permissions": [
    "storage"
  ],
  "host_permissions": [
    "https://api.example.com/*"
  ],
  "background": {
    "service_worker": "background.js"
  },
  "options_ui": {
    "page": "options.html"
  },
  "browser_specific_settings": {
    "kiririn": {
      "id": "com.example.sample",
      "strict_min_version": "0.2.0",
      "strict_max_version": "*",
      "update_url": "https://example.com/plugins/sample/update.json",
      "views": {
        "overlay": {
          "page": "overlay.html"
        },
        "panel": {
          "page": "panel.html"
        }
      }
    }
  }
}
```

### トップレベルの項目

| key | 必須 | 現在の実装 |
| --- | --- | --- |
| `manifest_version` | 実質必須 | WebExtension Manifest Version 3を指定します。 |
| `name` | 必須 | 前後の空白を除いて空でない文字列。プラグイン一覧に表示されます。 |
| `version` | 必須 | 前後の空白を除いて空でない文字列。更新候補の数値比較にも使われます。SemVer形式自体は強制されません。 |
| `author` | 任意 | プラグイン詳細画面に表示されます。 |
| `description` | 任意 | プラグインの説明として詳細画面に表示されます。 |
| `homepage_url` | 任意 | 詳細画面から開くリンクです。 |
| `permissions` | 任意 | `storage`または`unlimitedStorage`の配列です。 |
| `host_permissions` | 任意 | WebExtensionのhost match patternの配列です。 |
| `background` | 任意 | 背景ページまたはService Workerを定義します。存在する場合、ランタイムが保持されます。 |
| `options_ui` | 任意 | 設定画面を定義します。`page`を指定します。 |
| `browser_specific_settings.kiririn` | 必須 | kiririn固有のID、表示ページ、互換性、更新設定です。 |

`name`、`version`、`id`は前後の空白を除去して判定されます。`version`の比較は`String.compare(options: .numeric)`相当で、更新時にのみ使われます。

### `browser_specific_settings.kiririn`

| key | 必須 | 説明 |
| --- | --- | --- |
| `id` | 必須 | 空でないプラグイン識別子。インストール済みプラグイン間で一意にしてください。 |
| `views.overlay.page` | 条件付き | オーバーレイのHTMLページへの相対パスです。 |
| `views.panel.page` | 条件付き | パネルのHTMLページへの相対パスです。 |
| `update_url` | 任意 | 更新マニフェストのHTTP(S) URLです。自動更新ではなく、詳細画面から手動で確認します。 |
| `strict_min_version` | 任意 | この値未満のアプリでは互換性なしと判定します。 |
| `strict_max_version` | 任意 | この値を超えるアプリでは互換性なしと判定します。`*`は上限なしです。 |

`id`に対して現在のmanifest parserは正規表現による文字種制限を行っていません。ただし、URLパスや更新キーとして扱うため、実用上は`com.example.plugin`のような逆順ドメイン形式を推奨します。インストール時のアーカイブファイル名では、英数字、`.`、`_`、`-`、`@`以外の文字が`_`に置換されます。

`strict_min_version`と`strict_max_version`の両方を指定する場合、`strict_max_version`が`*`でなければ、最小バージョンは最大バージョン以下でなければなりません。判定対象はアプリの`CFBundleShortVersionString`です。

### 表示ページのパス

以下のパスはすべてプラグインルートからの相対パスにし、参照先をアーカイブまたはローカルフォルダに含めてください。

- `/`で始めることはできません。
- 親ディレクトリを表す`..`を含めることはできません。
- プラグインルートの外側のファイルは参照できません。
- `overlay`と`panel`は`browser_specific_settings.kiririn.views`の下に置きます。
- 設定画面は`options_ui.page`に置きます。

表示ページは少なくとも1つ指定してください。`options_ui.page`だけ、または`overlay`だけのプラグインも作れます。

### `background`

manifest parserが受理する`background`のkeyは以下です。

- `page`
- `scripts`
- `service_worker`
- `persistent`
- `preferred_environment`

`scripts`は文字列配列、`service_worker`は文字列として、参照先をプラグインルートからの相対パスで指定します。`background.page`を含め、背景リソースは実際に存在するファイルを指定してください。`background`に上記以外のkeyがあると拒否されます。

背景ページは、表示ページとは別に標準WebExtension APIを使うための実行コンテキストです。表示ページとデータを共有する場合は、WebExtensionのruntime messagingやstorage APIを使ってください。

### 現在サポートしていないmanifest key

以下のkeyがmanifestにあると拒否されます。

- `content_scripts`
- `commands`
- `action`
- `browser_action`
- `page_action`

これら以外のWebExtension keyも、kiririn独自に動作を保証しているわけではありません。実際に利用できるかはWebKitのWebExtension実装に従います。

## `.kppx`パッケージ

### アーカイブ形式

`.kppx`はZIPアーカイブです。`manifest.json`はアーカイブのルートに置きます。

```text
sample.kppx
├── manifest.json
├── overlay.html
└── assets/
    ├── main.js
    └── style.css
```

安全性のため、以下のZIPエントリは拒否されます。

- 絶対パスのエントリ
- `..`をパス要素に含むエントリ
- シンボリックリンク

アーカイブを作成するときは、プラグインディレクトリの中身をルートにして圧縮します。親ディレクトリごと圧縮して、`MyPlugin/manifest.json`のような階層にならないようにしてください。

```bash
cd MyPlugin
zip -r ../sample.kppx . -x '*.DS_Store' -x '__MACOSX/*'
```

### 署名

配布用の署名は、Android APK Signature Schemeの以下の形式に対応しています。

- APK Signature Scheme v2
- APK Signature Scheme v3
- APK Signature Scheme v3.1

署名ブロックはZIPのCentral Directoryの直前に配置され、アーカイブ本体の改変を検出します。署名済みアーカイブを再圧縮・編集すると署名検証に失敗するため、最後に署名してください。

kiririnはアプリに組み込まれた信頼チェーンで署名を検証し、証明書チェーンと失効状態を確認します。署名状態の扱いは以下です。

| 状態 | 意味 | 開発者モード無効時 |
| --- | --- | --- |
| `verified` | 信頼チェーンで検証でき、失効していない署名 | `.kppx`を追加・更新・有効化できます |
| `selfSigned` | 署名自体は検証できるが、信頼チェーンに接続できない署名 | 追加・更新・有効化できません |
| `revoked` | 署名者証明書が失効している署名 | 追加・更新・有効化できません |
| `unsigned` | 対応する署名ブロックがないパッケージ | 追加・更新・有効化できません |

開発者モードを有効にすると、自己署名・失効済み署名・未署名の`.kppx`を扱えます。また、macOSではローカルフォルダを追加できます。開発者モードを無効にした時点で、`verified`以外の署名状態またはローカルフォルダのプラグインは無効化されます。

リリース版iOSでは、`.kppx`にv2/v3/v3.1の署名ブロックが必要です。署名ブロックがないパッケージは、開発者モードの有無にかかわらず追加できません。macOSおよびDEBUGビルドでは署名ブロック自体は任意ですが、開発者モードを無効にした通常利用では`verified`署名が必要です。

インストール済みの`.kppx`はファイル全体のSHA-256ハッシュも保存されます。保存後にアーカイブが変更されると、プラグインは内容確認が必要な状態としてブロックされ、無効化されます。

## Bridge API

Bridgeはプラグインページにだけ注入される`window.kiririn`です。背景ページなど、表示ページ以外で利用できるかはWebKitのページ構成に依存するため、Bridgeを使うコードは`window.kiririn`の存在を確認してください。

TypeScriptを使う場合は、[KiririnPluginBridge.d.ts](./KiririnPluginBridge.d.ts)をプロジェクトにコピーするか、型チェックの対象に追加してください。

### 初期化と購読

購読メソッドは、登録した時点の値を即座にはコールバックしません。初期値が必要な場合は、まず`get...()`を呼び、その後に`on...Change()`を登録してください。

```ts
const initialPlayables = window.kiririn.getPlayables();
renderPlayables(initialPlayables);

window.kiririn.onPlayablesChange(renderPlayables);

const initialStatuses = window.kiririn.getPlayerStatuses();
renderStatuses(initialStatuses);
window.kiririn.onPlayerStatusesChange(renderStatuses);
```

コールバック内の例外はBridge側で握りつぶされます。必要ならプラグイン側でログを出してください。

### 再生可能な対象: `Playable`

`getPlayables()`は現在アクティブなプレイヤーごとに、現在の`Playable`が存在する場合だけ要素を返します。

```ts
interface Playable {
  playerID: string;
  id: string;
  title: string;
  subtitle?: string;
  initialNetworkTime?: number;
  isSeekable: boolean;
  length?: number;
  program?: Program;
  service?: Service;
}
```

- `playerID`: プレイヤーを指定するためのIDです。プレイヤーを閉じるまで維持されます。
- `id`: 現在の再生対象のIDです。
- `title`: 番組名、サービス名、またはファイル名などの表示用タイトルです。
- `subtitle`: 番組説明などの副題です。存在しない場合があります。
- `initialNetworkTime`: ネットワーク時刻のUNIX epoch秒です。
- `isSeekable`: シーク可能かどうかです。ライブ放送などでは`false`になります。
- `length`: 再生時間の秒数です。存在しない場合があります。
- `program`: 番組メタデータです。存在しない場合があります。
- `service`: サービス・チャンネルメタデータです。存在しない場合があります。

`initialNetworkTime`、`Program.startAt`、`Program.endAt`はUNIX epoch秒の数値であり、JavaScriptの`Date`ではありません。

```ts
interface Program {
  name: string;
  description: string;
  startAt: number;
  endAt: number;
  duration: number;
  eventId?: number;
  extended: [string, string][];
  genres: Genre[];
}

interface Genre {
  lv1: number;
  lv2?: number;
  name: string;
}

interface Service {
  name: string;
  serviceId: number;
  networkId: number;
  type: {
    value: number;
    description: string;
  };
  channel?: {
    id: string;
    type: string;
  };
}
```

### 再生状態: `PlayerPlaybackState`

```ts
interface PlayerPlaybackState {
  playerID: string;
  playableID: string;
  isPlaying: boolean;
  time: number;
  position: number;
  isScrubbing: boolean;
  scrubPosition: number | null;
  rate: number;
  televisionDisplayRect: PlayerDisplayRect;
  videoDisplayRect: PlayerDisplayRect;
}

interface PlayerDisplayRect {
  x: number;
  y: number;
  width: number;
  height: number;
}
```

- `time`: 現在時刻の秒数です。
- `position`: 0〜1の正規化された再生位置です。MPEG-TSなどでバイト位置が利用できる場合は、その正規化値が優先されます。
- `isScrubbing`: ネイティブのシークバーをドラッグ中かどうかです。
- `scrubPosition`: ドラッグ中のシークバー位置です。0〜1の値を取り、ドラッグ中以外は`null`です。シークバーの表示位置を表すため、MPEG-TSなどでは`position`と一致しない場合があります。
- `rate`: 再生速度です。
- `televisionDisplayRect`: プレイヤー表示領域内で、テレビ画面またはデータ放送コンテンツが占める矩形です。
- `videoDisplayRect`: プレイヤー表示領域内で、映像が実際に表示されている矩形です。

矩形の座標系は左上原点で、プレイヤー表示領域の幅・高さをそれぞれ1とします。データ放送が表示されていない場合は、両方とも`{x: 0, y: 0, width: 1, height: 1}`です。

映像領域に合わせて要素を配置する例です。

```ts
function applyRect(element: HTMLElement, rect: PlayerDisplayRect) {
  element.style.left = `${rect.x * 100}%`;
  element.style.top = `${rect.y * 100}%`;
  element.style.width = `${rect.width * 100}%`;
  element.style.height = `${rect.height * 100}%`;
}
```

### 再生状態・プレイヤーの購読

```ts
getPlayables(): Playable[];
onPlayablesChange(callback: (playables: Playable[]) => void): void;

getPlayerStatuses(): PlayerPlaybackState[];
onPlayerStatusesChange(callback: (statuses: PlayerPlaybackState[]) => void): void;

getFocusedPlayerID(): string | null;
onFocusedPlayerIDChange(callback: (playerID: string | null) => void): void;

onPlayerClosed(callback: (playerID: string) => void): void;

getPlayable(playerID: string): Playable | null;
getPlayerStatus(playerID: string): PlayerPlaybackState | null;
```

`getFocusedPlayerID()`はアプリ全体でフォーカスされているプレイヤーを返します。フォーカス対象が閉じられた場合、`onFocusedPlayerIDChange`には`null`が渡され、その後`onPlayerClosed`が呼ばれます。

`getPlayable`と`getPlayerStatus`は対象がなければ`null`を返します。再生状態は頻繁に変わるため、必要な値だけUIへ反映してください。

シークバーのドラッグ開始・終了はすぐに通知します。ドラッグ中の位置更新は、Bridge負荷を抑えるため最大500msに1回です。

### 再生操作

```ts
play(playerID?: string): void;
pause(playerID?: string): void;
togglePlayPause(playerID?: string): void;
seek(position: number, playerID?: string): void;
seekToTime(time: number, playerID?: string): void;
```

`playerID`を省略した場合は、以下の順で対象を決めます。

1. メソッドに渡した`playerID`
2. オーバーレイまたはiOSパネルが内部的に持つ対象プレイヤー
3. アプリのフォーカス中のプレイヤー
4. 最初にアクティブなプレイヤー

対象プレイヤーがない場合、操作は無視されます。

- `seek`の`position`は0〜1にクランプされます。対象がシーク不可の場合は無視されます。
- `seekToTime`の`time`は秒数です。負数は0に、再生時間を超える値は再生時間にクランプされます。
- `seekToTime`はリモートファイルなどで正確な位置への移動を保証しません。

### 実行環境情報

```ts
interface KiririnRuntimeInfo {
  platform: "iOS" | "macOS";
  osVersion: string;
  appVersion: string | null;
  buildVersion: string;
  bundleIdentifier: string | null;
  bridgeVersion: number;
  displayAreaType: "overlay" | "panel" | "options";
  playerID: string | null;
}

const runtime = window.kiririn.getRuntimeInfo();
```

現在の`bridgeVersion`は`6`です。Bridgeの互換性を判定するときは、この値と`appVersion`を確認してください。

`osVersion`は`ProcessInfo.processInfo.operatingSystemVersionString`、`appVersion`は`CFBundleShortVersionString`、`buildVersion`は`CFBundleVersion`です。`bundleIdentifier`や`appVersion`は取得できない環境では`null`になります。

### セーフエリア

Bridgeは、表示領域に重ならないようにするための値をCSSカスタムプロパティとして設定します。

```css
.toolbar {
  padding-top: var(--kiririn-safe-area-inset-top);
  padding-right: var(--kiririn-safe-area-inset-right);
  padding-bottom: var(--kiririn-safe-area-inset-bottom);
  padding-left: var(--kiririn-safe-area-inset-left);
}
```

利用できる変数は以下です。

- `--kiririn-safe-area-inset-top`
- `--kiririn-safe-area-inset-right`
- `--kiririn-safe-area-inset-bottom`
- `--kiririn-safe-area-inset-left`

値の単位はCSSのpx相当です。オーバーレイでは通常0です。設定画面ではOSのセーフエリア、パネルでは折りたたみバーやプラグイン切り替えUIの予約領域も含まれます。

### Deep Linkの受信

プラグイン固有のDeep Linkは以下の形式です。

```text
kiririn://plugins/{manifestID}/任意のパス?key=value
```

インストール済みで、URL中のパス先頭の`manifestID`と一致するプラグインに、URL全体が配送されます。

```ts
window.kiririn.onDeeplinkOpened(({ url }) => {
  const callbackURL = new URL(url);
  console.log(callbackURL.pathname, callbackURL.searchParams.get("key"));
});
```

```ts
interface DeeplinkOpenedPayload {
  url: string;
}
```

ページが読み込み完了する前に届いたDeep Linkはキューに入れられ、ページの読み込み完了後に配送されます。プラグインが有効化されていない場合や、対象ページが表示されていない場合は、受信できるページが表示されるまで保留されることがあります。

Deep LinkのパスにIDや任意データを含める場合は、URLコンポーネントとして正しくエンコードしてください。

### キャプチャ

キャプチャ通知は、購読を登録した後に発生したキャプチャだけが対象です。過去のキャプチャは再送されません。

```ts
window.kiririn.onCaptureTaken(async (capture) => {
  const original = await window.kiririn.getCaptureBlob(
    capture.captureID,
    "original"
  );
  if (original) {
    const imageURL = URL.createObjectURL(original);
    document.querySelector("img")?.setAttribute("src", imageURL);
  }
});
```

```ts
type CaptureVariant = "original" | "composite";

interface CaptureVariantMetadata {
  type: CaptureVariant;
  overlayPluginManifestIDs: string[];
}

interface CaptureMetadata {
  captureID: string;
  playerID: string;
  capturedAt: Date;
  variants: CaptureVariantMetadata[];
}
```

- `captureID`: `getCaptureBlob`に渡すキャプチャIDです。
- `playerID`: キャプチャ元のプレイヤーIDです。
- `capturedAt`: JavaScriptの`Date`です。
- `variants`: 利用できる画像種別の一覧です。
- `original`: プラグインオーバーレイを合成していない元画像です。常にイベントに含まれます。
- `composite`: データ放送やプラグインオーバーレイを合成した画像です。合成画像が生成された場合だけ含まれます。
- `overlayPluginManifestIDs`: `composite`に含まれるオーバーレイプラグインのmanifest IDです。

`onCaptureTaken`が受け取るイベントの範囲は以下です。

- オーバーレイ: そのオーバーレイが紐付いたプレイヤーのキャプチャだけ
- iOSのパネル: 紐付いたプレイヤーのキャプチャだけ
- 設定画面およびmacOSの独立パネル: 全プレイヤーのキャプチャ

```ts
getCaptureBlob(
  captureID: string,
  variant: "original" | "composite"
): Promise<Blob | null>;
```

イベントで通知されていない`captureID`、そのコンテキストで使えないvariant、または対象ファイルがない場合は以下の扱いになります。

- 要求形式やアクセス範囲が不正な場合、Promiseはrejectされます。
- 対象画像が削除済みなどで読み込めない場合、`null`でresolveされます。
- 成功時は画像データを含む`Blob`がresolveされます。通常はJPEGのMIME typeが設定されます。

### 任意メッセージ

```ts
sendMessage(type: string, data: any): void;
```

一方向のメッセージをネイティブ側へ送信します。現在のネイティブ側で処理される公開メッセージ型はありません。未定義の`type`は無視され、応答もありません。再生操作・キャプチャ取得は専用APIを使ってください。`window.webkit.messageHandlers.kiririn`を直接呼び出すことや、`_`で始まるBridge内部メソッドを利用することはサポート対象外です。

## Deep Linkによるインストール

更新マニフェストからプラグインを追加するためのDeep Linkがあります。

```text
kiririn://plugins/?updateManifestUrl=https%3A%2F%2Fexample.com%2Fplugins%2Fsample%2Fupdate.json&manifestID=com.example.sample
```

クエリに`updateManifestUrl`が存在すると、通常のプラグインコールバックではなくインストール要求として扱われます。

- `updateManifestUrl`はHTTPまたはHTTPSにしてください。
- `manifestID`は空でない文字列にしてください。
- URLはURLエンコードしてください。
- 取得後に通常のmanifest検証、互換性検証、署名検証が行われます。

## 更新

更新は自動ではありません。`update_url`を持つ署名済み`.kppx`だけ、プラグイン詳細画面から「アップデートを確認する」を選べます。

### 更新マニフェストの形式

`update_url`は以下のJSONを返します。

```json
{
  "addons": {
    "com.example.sample": {
      "updates": [
        {
          "version": "1.3.0",
          "update_link": "https://example.com/plugins/sample-1.3.0.kppx",
          "update_hash": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          "update_info_url": "https://example.com/plugins/sample/releases/1.3.0",
          "applications": {
            "kiririn": {
              "strict_min_version": "0.2.0",
              "strict_max_version": "*"
            }
          }
        }
      ]
    }
  }
}
```

| key | 必須 | 説明 |
| --- | --- | --- |
| `addons` | 必須 | manifest IDをkeyにしたオブジェクトです。 |
| `addons[manifestID].updates` | 必須 | 更新候補の配列です。 |
| `version` | 推奨 | 更新候補のバージョンです。現在バージョンとの比較やパッケージ側のversion照合に使われます。 |
| `update_link` | 必須 | ダウンロードする`.kppx`のHTTP(S) URLです。 |
| `update_hash` | 条件付き | `sha256:`+64桁または`sha512:`+128桁の16進数です。 |
| `update_info_url` | 任意 | 更新完了後の画面から開くURLです。 |
| `applications.kiririn` | 条件付き | kiririn向けの互換性条件です。 |

`update_link`がHTTPSの場合、`update_hash`は省略できます。HTTPの場合は`update_hash`が必須です。指定したハッシュは、ダウンロードした`.kppx`のバイト列全体に対して検証されます。

`applications`自体を省略した候補は互換とみなされます。`applications`を指定する場合は`kiririn`を含めてください。`applications`があるのに`kiririn`がない候補は互換なしとして除外されます。

`applications.kiririn`では次の項目が使われます。

- `strict_min_version`: 現在のアプリがこの値未満なら除外
- `strict_max_version`: 現在のアプリがこの値を超えていれば除外。`*`は上限なし
- `advisory_max_version`: 現在は判定に使われません

更新候補は、互換性のある候補から`version`を数値比較して降順に並べ、利用可能なダウンロードURLを持つ最初の候補が選ばれます。既存プラグインの更新では、候補バージョンが現在バージョンより新しくなければ更新できません。

`update.json`の`version`と、ダウンロードした`.kppx`の`manifest.json`の`version`が両方指定されている場合は、文字列として完全一致する必要があります。リリース時は必ず両方を同じ値にしてください。

### 更新時の署名

既存プラグインを更新するには、以下の条件を満たしてください。

- インストール済みパッケージが署名済みであること
- 更新先パッケージも署名済みであること
- 更新先のmanifest IDが既存のIDと同じであること
- 通常モードでは、署名者の公開鍵SPKIのSHA-256値が既存パッケージと一致すること

公開鍵ハッシュが一致しない更新は、開発者モードでは警告付きで確認できますが、通常モードでは拒否されます。未署名プラグインに`update_url`を設定しても、既存プラグインの更新機能は有効になりません。

## 開発時の運用

### macOSのローカルフォルダ

macOSでは、開発者モードを有効にするとフォルダを直接追加できます。

```text
MyPlugin/
└── manifest.json
```

ローカルフォルダは`.kppx`に圧縮せず、そのままWebExtensionリソースとして読み込まれます。`manifest.json`の変更は監視され、manifestの再検証とプラグインの再読み込みが行われます。HTML、JavaScript、CSSだけを変更した場合は、必要に応じてプラグインを再読み込みしてください。

ローカルフォルダは常に未署名扱いで、`update_url`を指定しても更新確認の対象にはなりません。ローカルフォルダを既存プラグインのパッケージ版へ差し替える場合も開発者モードが必要です。

### Web Inspector

プラグインのWebExtensionコンテキストとWebViewはInspectableとして作成されます。開発中はSafariのWeb Inspectorなど、WebKit対応のインスペクタを利用できます。

ただし、プラグインページでは`window.onerror`と`unhandledrejection`がアプリのアラートに接続されています。未処理の例外やPromise rejectionは、利用者にアラートとして表示されることがあります。
