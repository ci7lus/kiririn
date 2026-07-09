# kiririn

macOS/iOS 向け日本テレビ放送規格(ARIB)用 MPEG-TS プレイヤー

## 技術

- 言語: Swift
- フレームワーク: SwiftUI
- プレイヤー: カスタム VLCKit（ARIB 追加サポート）

## ルール

- コメントはコミットを前提に記入する。コミットされるべきでないコメントは記載しない。
- SwiftUI 向けのスキルや Swift Concurrency 向けのスキルがあれば使用する。
  - iOS 及び macOS 向けにビルドが通せる状態を維持する。
    - `if os(iOS)` / `if os(macOS)` は UI 固有のコンポーネントにのみ使用する。
    - ビジネスロジックはプラットフォーム非依存に保つ。
  - Swift ファイルを編集した場合、編集後にビルドが通るか確認する。
    - iOS と macOS の両方に影響があるものであれば両方、片方だけであれば片方だけビルドし、実装起因で落ちたらその場で修正する。
    - 検証順は特段理由がなければ iOS から macOS の順にする。
    - ビルド前に必ず Xcode MCP の利用可否を確認する。ツール一覧に Xcode MCP が表示されていない場合でも、`tool_search` が利用可能なら Xcode MCP を検索し、呼び出せる状態にしてから判断する。
      - Xcode MCP が利用可能な場合は `XcodeListWindows` で開いているタブを確認し、このリポジトリの `kiririn.xcodeproj` または `kiririn.xcworkspace` が存在するか確認する。
      - 対象タブが存在する場合は、`misc/build.scpt` ではなく Xcode MCP 経由でビルド操作を行う。
      - Xcode MCP でビルドする場合は、対象タブがこのリポジトリの `kiririn` であることを確認してからビルドし、失敗時は MCP のビルド結果とログ上の原因を報告する。
      - `tool_search` でも Xcode MCP が見つからない、Xcode MCP が利用できない、または対象タブが存在しない場合は、`xcodebuild` は明示的な許可がないかぎり絶対に使わず、以下のコマンドを用いる。
        - iOS の検証例: `osascript misc/build.scpt ios`
        - macOS の検証例: `osascript misc/build.scpt macos`
        - これらのコマンドはビルド成功時に `build success` と出力し、失敗の場合は原因を出力する。成功時も警告は Warning として出力されるため、修正を試みる。
        - ビルド確認のために追加の AppleScript を組み立てて `osascript -e` で実行してはならない。`misc/build.scpt` をそのまま実行する。
        - `misc/build.scpt` 実行前後を含め、ビルド確認のために `open`, `xed`, `open -a Xcode`, `xcodebuild` などで Xcode や `.xcodeproj` / `.xcworkspace` を操作してはならない。
        - `tell application "Xcode"` を使った独自の補助操作、たとえば document 数の確認、active document の確認、build の直接実行、window/document/workspace の open/close/activate、run destination の確認や変更を行ってはならない。
        - `misc/build.scpt` が失敗した場合も、勝手に前提条件を補う補助コマンドを打たず、失敗内容をそのまま報告する。追加操作が必要なら必ずユーザーに確認する。
- 強制アンラップより `guard let` を優先する。
- View の body はシンプルに保ち、複雑なロジックは ViewModel または Coordinator に移す。
- 作業の終了後、ソースコードに変更があれば以下の作業を行う。
  - 変更をレビューし、不適切なものがあれば修正する。
  - 変更を表したコミットメッセージを日本語で考え、出力する。
    - フォーマットは `chore/feat: XXX` 形式
- UI に表示するメッセージにおいて、ascii と非 ascii の間に半角アキを入れない。

## 禁止事項

- メインターゲットの再生に対応していないため、`AVFoundation` を使用しない。
