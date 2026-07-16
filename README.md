# kiririn

kiririn は macOS/iOS 上で日本のデジタル放送を視聴する体験を研究する目的で配布される研究資料です。<br>
本アプリに CAS 処理は含まれていないため、暗号化された放送データを視聴することはできません。<br>
放送視聴機能を利用するには利用者自身が管理する [Chinachu/Mirakurun](https://github.com/Chinachu/Mirakurun) または [l3tnun/EPGStation](https://github.com/l3tnun/EPGStation) が必要です。

## 機能

アプリの主な機能は次のとおりです。

- 番組情報の表示 (MPEG2-TS のみ)
- 番組表の表示 (Mirakurun / EPGStation 接続時)
- 録画の再生 (EPGStation / KonomiTV / Google Drive 接続時)
- キャプチャ画像の簡易管理
- [プラグイン](#プラグイン)による機能拡張

動画再生周りの機能は次のとおりです。(VLCKit 由来)

- MPEG2-TS の再生
- ARIB STD-B24 形式の字幕表示 (libaribcaption)
- デュアルモノ対応
- 5.1ch 音声の仮想サラウンド化
- MMT/TLV の再生 (部分的なサポート・superfashi/FFmpeg)
- HDR 表示
- PiP (iOS のみ)

## 実行方法

> [!NOTE]
> 本アプリを実行すると、一部のログやパフォーマンス情報・クラッシュ情報が Sentry を通じて収集されます。

### macOS

[Releases](https://github.com/ci7lus/kiririn/releases) から最新のリリースをダウンロードできます。<br>
macOS 15.4 (Sequoia) 以上での実行に対応しているはずです。動作確認は 26.5.2 で行っています。

### iOS

プレリリース版を TestFlight にて配布しています。<br>
TestFlight 参加リンクは [Releases](https://github.com/ci7lus/kiririn/releases) に記載しています。<br>
iOS 18.4 以上での実行に対応しているはずです。動作確認は 26.5.2 で行っています。

## プラグイン

仕様は [Plugin/README.md](Plugin/README.md) を参照してください。<br>
プラグインには有効な署名が必要です。macOS 版では有効な署名がないプラグインを導入できますが、iOS 版では導入できません。この制限の緩和については検討中です。<br>
サンプル実装は [ci7lus/kiririn-plugins](https://github.com/ci7lus/kiririn-plugins) にあります。

## 開発

```bash
git clone https://github.com/ci7lus/kiririn.git
cd kiririn
./setup.sh
open kiririn.xcodeproj
```

### VLCKit について

VLCKit は[フォーク](https://github.com/neneka/vlckit)して改変したものを使用しています。<br>
`setup.sh` を実行するとダウンロードされます。<br>

## 謝辞

本アプリは次のプロジェクトを利用または参考にして実装しています。

- [videolan/vlc](https://github.com/videolan/vlc)
- [videolan/vlckit](https://github.com/videolan/vlckit)
- [xqq/libaribcaption](https://github.com/xqq/libaribcaption)
- [xtne6f/tsreadex](https://github.com/xtne6f/tsreadex)
- [superfashi/FFmpeg](https://github.com/superfashi/FFmpeg)
- [Chinachu/Mirakurun](https://github.com/Chinachu/Mirakurun)
- [l3tnun/EPGStation](https://github.com/l3tnun/EPGStation)
- [tsukumijima/KonomiTV](https://github.com/tsukumijima/KonomiTV)

### プロ生ちゃん アプリ開発支援プログラムについて

本アプリは、[プロ生ちゃん アプリ開発支援プログラム](https://kei.pronama.jp/pronama-chan-developer-support-program/)のサポートを受けています。<br>
macOS 版の公証や TestFlight 配布のための各種手続きについてサポートいただいています。

## ライセンス

MPL 2.0
