import Foundation

public struct MIMEType: Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static func forExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm":  return "text/html; charset=utf-8"
        case "css":          return "text/css"
        case "js", "mjs":   return "application/javascript"
        case "json":         return "application/json"
        case "xml":          return "application/xml"
        case "txt":          return "text/plain; charset=utf-8"
        case "png":          return "image/png"
        case "jpg", "jpeg":  return "image/jpeg"
        case "gif":          return "image/gif"
        case "webp":         return "image/webp"
        case "svg":          return "image/svg+xml"
        case "ico":          return "image/x-icon"
        case "avif":         return "image/avif"
        case "woff":         return "font/woff"
        case "woff2":        return "font/woff2"
        case "ttf":          return "font/ttf"
        case "otf":          return "font/otf"
        case "pdf":          return "application/pdf"
        case "zip":          return "application/zip"
        case "mp4":          return "video/mp4"
        case "webm":         return "video/webm"
        case "ogg":          return "video/ogg"
        case "mp3":          return "audio/mpeg"
        case "wav":          return "audio/wav"
        case "flac":         return "audio/flac"
        default:             return "application/octet-stream"
        }
    }
}
