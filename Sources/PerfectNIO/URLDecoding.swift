import Foundation

extension String {
    // Percent-decode a URL-encoded string; treats + as space (application/x-www-form-urlencoded)
    var stringByDecodingURL: String? {
        replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    var filePathExtension: String {
        URL(fileURLWithPath: self).pathExtension
    }
}

extension Date {
    init?(fromISO8601 string: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { self = date; return }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { self = date; return }
        return nil
    }
}
