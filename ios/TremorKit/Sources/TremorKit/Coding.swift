// JSON coding that matches FastAPI. The backend writes datetimes with Python's isoformat(): microseconds
// ("2026-11-24T10:00:00.123456+00:00"), sometimes no fraction, sometimes no offset (treated as UTC).
import Foundation

public enum WireDate {
    /// Parses ISO-8601 with any number of fractional digits, a `Z` or `±hh:mm` offset, or no offset (UTC).
    public static func parse(_ s: String) -> Date? {
        var body = s
        var offset = 0
        if body.hasSuffix("Z") || body.hasSuffix("z") {
            body.removeLast()
        } else if let r = body.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) {
            let tz = body[r].replacingOccurrences(of: ":", with: "")
            let sign = tz.hasPrefix("-") ? -1 : 1
            let digits = tz.dropFirst()
            guard let h = Int(digits.prefix(2)), let m = Int(digits.suffix(2)) else { return nil }
            offset = sign * (h * 3600 + m * 60)
            body.removeSubrange(r)
        }
        var fraction = 0.0
        if let dot = body.firstIndex(of: ".") {
            let digits = body[body.index(after: dot)...]
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let f = Double("0." + digits) else { return nil }
            fraction = f
            body = String(body[..<dot])
        }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let base = parser.date(from: body) else { return nil }
        return base.addingTimeInterval(fraction - Double(offset))
    }

    /// UTC with millisecond precision, e.g. "2026-11-24T10:00:00.123Z".
    public static func format(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}

public extension JSONDecoder {
    static var tremor: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = WireDate.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO-8601 datetime: \(s)")
            }
            return date
        }
        return d
    }
}

public extension JSONEncoder {
    static var tremor: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(WireDate.format(date))
        }
        return e
    }
}
