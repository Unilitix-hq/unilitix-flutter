// VENDORED from UnilitixCore 0.8.0 (Models.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation

/// A JSON value, so event properties and metadata survive the on-device
/// queue and encode to exactly what the app passed.
public enum JSONValue: Codable, Equatable {
    case string(String)
    case int(Int64)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    /// Converts a value from an app-supplied `[String: Any]`. Values JSON
    /// cannot represent are stored as their description; non-finite numbers
    /// (NaN, ±infinity) become `null`, since JSON has no form for them.
    public init(any value: Any?) {
        guard let value = value else { self = .null; return }
        switch value {
        case let v as JSONValue: self = v.sanitized
        case let v as String: self = .string(v)
        case let v as NSNumber:
            if CFGetTypeID(v) == CFBooleanGetTypeID() {
                self = .bool(v.boolValue)
            } else if CFNumberIsFloatType(v) {
                let d = v.doubleValue
                self = d.isFinite ? .number(d) : .null
            } else {
                self = .int(v.int64Value)
            }
        case let v as [Any]: self = .array(v.map { JSONValue(any: $0) })
        case let v as [String: Any]: self = .object(v.mapValues { JSONValue(any: $0) })
        case let v as Date: self = .string(ISO8601.string(from: v))
        case let v as URL: self = .string(v.absoluteString)
        case is NSNull: self = .null
        default: self = .string(String(describing: value))
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        // JSONEncoder throws on NaN and infinity; write null instead.
        case .number(let v): if v.isFinite { try c.encode(v) } else { try c.encodeNil() }
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    /// This value with every non-finite number replaced by `null`.
    var sanitized: JSONValue {
        switch self {
        case .number(let d): return d.isFinite ? self : .null
        case .array(let v): return .array(v.map { $0.sanitized })
        case .object(let v): return .object(v.mapValues { $0.sanitized })
        default: return self
        }
    }

    static func objectMap(from dict: [String: Any]) -> [String: JSONValue] {
        dict.mapValues { JSONValue(any: $0) }
    }
}

/// One event as the ingest API expects it (`IngestEvent` in openapi.sdk.json).
/// Optional fields that are nil are omitted on the wire.
struct IngestEvent: Codable, Equatable {
    var eventId: String
    var seq: Int?
    var type: String
    var screen: String
    var timestamp: String
    var x: Double?
    var y: Double?
    var properties: [String: JSONValue]?
    var metadata: [String: JSONValue]?
    var title: String?
    var fatal: Bool?
    var exceptionType: String?
    var exceptionMessage: String?
    var stackTrace: String?
    var breadcrumbs: [[String: JSONValue]]?
    /// The contract network type when the event was captured (`WIFI`,
    /// `ETHERNET`, `5G`, `4G`, `3G`, `2G`, `CELLULAR`, `OFFLINE`, `UNKNOWN`).
    var networkAtCapture: String?
    /// The device was offline when the event was captured.
    var capturedOffline: Bool?

    init(type: String, screen: String, at date: Date = Date()) {
        eventId = UUID().uuidString.lowercased()
        self.type = type
        self.screen = screen
        timestamp = ISO8601.string(from: date)
    }
}

/// The parts of a session the API needs to create or update its record.
struct SessionInfo: Codable, Equatable {
    var id: String
    var startedAt: Date
    var lastActivityAt: Date
    var crashed: Bool = false
    var customUserId: String?
    /// The anonymous id when the session started (0.8.0). A session's
    /// events keep their ids after `reset()`; nil in queues written by
    /// older versions (the current id is sent then).
    var anonymousId: String?
}

/// `IngestSessionRequest` in openapi.sdk.json: the session record plus a batch
/// of its events, sent in one request per flush.
struct IngestSessionRequest: Encodable {
    var sessionId: String
    var anonymousId: String
    var installId: String
    var customUserId: String?
    var sdkVersion: String
    var os: String
    var osVersion: String
    var deviceModel: String
    var manufacturer: String
    var deviceType: String
    var appVersion: String
    var buildNumber: String
    var packageName: String
    var screenWidth: Int?
    var screenHeight: Int?
    var screenDensity: Double?
    var locale: String
    var timezone: String
    var startedAt: String
    var durationMs: Int64
    var crashed: Bool
    /// Free-form; set when a wrapper SDK embeds this engine
    /// (`UnilitixVersion.sessionData`).
    var sessionData: [String: JSONValue]?
    var events: [IngestEvent]
}

/// `IdentifyRequest` in openapi.sdk.json. Codable: held requests are kept
/// in `Preferences` until the API answers them.
struct IdentifyRequest: Codable, Equatable {
    var anonymousId: String
    var customUserId: String
    var traits: [String: JSONValue]?
}

enum ISO8601 {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let lock = NSLock()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func string(from date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return formatter.string(from: date)
    }

    /// RFC 3339 with or without fractional seconds.
    static func date(from s: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return formatter.date(from: s) ?? plain.date(from: s)
    }
}

/// `ScreenshotInitRequest` in openapi.sdk.json: reserve upload slots.
struct ScreenshotInitRequest: Encodable {
    var sessionId: String
    var count: Int
    var ordinals: [Int]
    /// "jpeg" for iOS frames; the API defaults to webp when absent.
    var format: String
    /// Each frame's exact byte size, in `ordinals` order (0.8.0): the API
    /// then signs Content-Length into each presigned PUT.
    var sizes: [Int]?
}

/// `ScreenshotInitResponse` in openapi.sdk.json.
struct ScreenshotInitResponse: Decodable {
    struct Slot: Decodable {
        var ordinal: Int
        var presignedUrl: String
        var r2Key: String?
    }
    var slots: [Slot]
}

/// `ScreenshotConfirmItem` in openapi.sdk.json: the frame's metadata, which
/// the API stores only from this call.
struct ScreenshotConfirmItem: Encodable {
    var ordinal: Int
    var bytes: Int
    var capturedAt: String
    var screenName: String
    var viewportWidth: Int
    var viewportHeight: Int
}

/// `ScreenshotConfirmRequest` in openapi.sdk.json.
struct ScreenshotConfirmRequest: Encodable {
    var sessionId: String
    var screenshots: [ScreenshotConfirmItem]
}

/// Contract 1.4.0 value limits, applied to everything the app passes in:
/// event properties, identify traits, names, screen names and user ids.
///
/// - strings: at most `SdkContract.maxStringLength` UTF-16 code units,
///   never splitting a surrogate pair;
/// - maps: at most `SdkContract.maxPropertyKeys` keys (the first in key
///   order); lists: at most that many items;
/// - nesting: the top-level map is level 1; a map or list deeper than
///   `SdkContract.maxPropertyDepth` becomes `SdkContract.truncatedMarker`;
/// - NaN and ±infinity become `null`.
enum PropertyNormalizer {
    static func string(_ s: String, max: Int = SdkContract.maxStringLength) -> String {
        let units = s.utf16
        guard units.count > max, max > 0 else { return max > 0 ? s : "" }
        var end = units.index(units.startIndex, offsetBy: max)
        // Never keep half of a surrogate pair.
        if UTF16.isLeadSurrogate(units[units.index(before: end)]) { end = units.index(before: end) }
        return String(decoding: Array(units[units.startIndex..<end]), as: UTF16.self)
    }

    /// A properties or traits map, normalised.
    static func properties(_ dict: [String: Any]) -> [String: JSONValue] {
        normalizedObject(JSONValue.objectMap(from: dict), level: 1)
    }

    /// Already-converted values (metadata from wrappers), normalised.
    static func properties(_ dict: [String: JSONValue]) -> [String: JSONValue] {
        normalizedObject(dict, level: 1)
    }

    private static func normalizedObject(_ o: [String: JSONValue], level: Int) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for key in o.keys.sorted().prefix(SdkContract.maxPropertyKeys) {
            out[string(key)] = child(o[key] ?? .null, level: level)
        }
        return out
    }

    /// A value inside a container at `level`.
    private static func child(_ v: JSONValue, level: Int) -> JSONValue {
        switch v {
        case .array(let a):
            guard level + 1 <= SdkContract.maxPropertyDepth else { return .string(SdkContract.truncatedMarker) }
            return .array(a.prefix(SdkContract.maxPropertyKeys).map { child($0, level: level + 1) })
        case .object(let o):
            guard level + 1 <= SdkContract.maxPropertyDepth else { return .string(SdkContract.truncatedMarker) }
            return .object(normalizedObject(o, level: level + 1))
        case .string(let s):
            return .string(string(s))
        case .number(let d):
            return d.isFinite ? v : .null
        default:
            return v
        }
    }
}
