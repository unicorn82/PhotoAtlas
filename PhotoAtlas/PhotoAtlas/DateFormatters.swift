import Foundation

enum DateFormatters {
    static let shared = Shared()

    final class Shared {
        let shortDateTime: DateFormatter

        init() {
            let df = DateFormatter()
            df.locale = .current
            df.timeZone = .current
            df.dateStyle = .medium
            df.timeStyle = .short
            self.shortDateTime = df
        }
    }
}
