import Foundation

extension FormatStyle where Self == Date.FormatStyle {
    /// 年月日・時刻を表示する
    /// 例: 2026年4月29日 14:30
    static var displayDateTimeFull: Self {
        .dateTime.year().month().day().hour().minute()
    }

    /// 月日・時刻を表示する
    /// 例: 4月29日 14:30
    static var displayDateTime: Self {
        .dateTime.month().day().hour().minute()
    }

    /// 時刻のみを表示する
    /// 例: 14:30
    static var displayTime: Self {
        .dateTime.hour().minute()
    }
}
