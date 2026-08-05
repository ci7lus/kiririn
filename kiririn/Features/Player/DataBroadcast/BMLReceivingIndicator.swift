/// 実機の画面下に出る「データ取得中...」「通信中...」表示。
enum BMLReceivingIndicator: Equatable {
    case receiving
    case networking

    var displayText: String {
        switch self {
        case .receiving: "データ取得中..."
        case .networking: "通信中..."
        }
    }

    /// どちらの表示を出すか(出さないならnil)を決める。
    ///
    /// コンテンツ表示中だけでなく`isPresentationPending`も対象にするのが要点で、
    /// 選局後に初めてdボタンを押したときは起動文書のモジュール取得が終わるまで
    /// コンテンツが出ない - コンテンツ表示中だけを条件にすると、いちばん待たされる
    /// 初回読み込みでこそ何も出ないことになる。
    /// 両方進行中なら実機と同様に通信中を優先。
    static func current(
        isContentVisible: Bool,
        isPresentationPending: Bool,
        isReceiving: Bool,
        isNetworking: Bool
    ) -> BMLReceivingIndicator? {
        guard isContentVisible || isPresentationPending else { return nil }
        if isNetworking { return .networking }
        if isReceiving { return .receiving }
        return nil
    }
}
