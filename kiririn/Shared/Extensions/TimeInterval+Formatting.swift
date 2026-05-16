import Foundation

extension TimeInterval {
    /// プレイヤー向けの時間表示を m:ss または h:mm:ss で返す
    var playerTimeString: String {
        let totalSeconds = max(0, Int(self.rounded(.towardZero)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
