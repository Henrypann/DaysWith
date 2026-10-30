import Foundation
import ImageIO
import AVFoundation

struct ImportedCaptureTime {
    var millis: Int64
    var metadata: CaptureMetadata

    static func library(_ date: Date) -> ImportedCaptureTime {
        ImportedCaptureTime(millis: Int64(date.timeIntervalSince1970 * 1000),
                            metadata: CaptureMetadata(source: "photosCreationDate"))
    }

    static func unknown(source: String) -> ImportedCaptureTime {
        ImportedCaptureTime(millis: 0, metadata: CaptureMetadata(source: source))
    }
}

enum MediaImportMetadata {
    static func image(_ url: URL) -> ImportedCaptureTime {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return .unknown(source: "missingMetadata")
        }
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        guard let text = (exif["DateTimeOriginal"] as? String) ?? (exif["DateTimeDigitized"] as? String)
                ?? (tiff["DateTime"] as? String) else { return .unknown(source: "missingMetadata") }
        let offset = (exif["OffsetTimeOriginal"] as? String) ?? (exif["OffsetTimeDigitized"] as? String)
        let subsec = (exif["SubsecTimeOriginal"] as? String) ?? (exif["SubsecTimeDigitized"] as? String)
        return parseEXIF(text, offset: offset, subsecond: subsec)
    }

    static func parseEXIF(_ text: String, offset: String?, subsecond: String? = nil) -> ImportedCaptureTime {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        // Validate wall-clock components using UTC. Unknown-zone values remain unknown instants.
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let wallDate = formatter.date(from: text) else { return .unknown(source: "invalidEXIF") }
        let normalized = text.replacingOccurrences(of: ":", with: "-", range: text.startIndex..<text.index(text.startIndex, offsetBy: min(10, text.count)))
        guard let offset, let minutes = timezoneMinutes(offset) else {
            return ImportedCaptureTime(millis: 0, metadata: CaptureMetadata(source: "exifLocalTime", localDateTime: normalized, isEstimated: true))
        }
        let fraction = subsecond.flatMap { Double("0." + $0.filter(\.isNumber)) } ?? 0
        let instant = wallDate.timeIntervalSince1970 - Double(minutes * 60) + fraction
        return ImportedCaptureTime(millis: Int64(instant * 1000), metadata: CaptureMetadata(source: "exif", timezoneOffsetMinutes: minutes, localDateTime: normalized))
    }

    static func movie(_ url: URL) -> ImportedCaptureTime {
        let asset = AVURLAsset(url: url)
        let items = asset.commonMetadata + asset.metadata(forFormat: .quickTimeMetadata)
        for item in items where item.commonKey == .commonKeyCreationDate || (item.identifier?.rawValue.lowercased().contains("creationdate") ?? false) {
            guard let text = item.stringValue else { continue }
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = parser.date(from: text) ?? ISO8601DateFormatter().date(from: text)
            if let date {
                let zone = text.hasSuffix("Z") ? 0 : timezoneMinutes(String(text.suffix(6)))
                return ImportedCaptureTime(millis: Int64(date.timeIntervalSince1970 * 1000), metadata: CaptureMetadata(source: "quickTime", timezoneOffsetMinutes: zone, localDateTime: text))
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            formatter.isLenient = false
            if formatter.date(from: text) != nil {
                return ImportedCaptureTime(millis: 0, metadata: CaptureMetadata(source: "quickTimeLocalTime", localDateTime: text.replacingOccurrences(of: "T", with: " "), isEstimated: true))
            }
        }
        return .unknown(source: "missingMetadata")
    }

    private static func timezoneMinutes(_ text: String) -> Int? {
        if text == "Z" { return 0 }
        let parts = text.split(separator: ":")
        guard parts.count == 2, text.first == "+" || text.first == "-", parts[0].count == 3,
              let hours = Int(parts[0].dropFirst()), let minutes = Int(parts[1]), hours <= 14, minutes < 60,
              hours < 14 || minutes == 0 else { return nil }
        return (hours * 60 + minutes) * (text.first == "-" ? -1 : 1)
    }
}
