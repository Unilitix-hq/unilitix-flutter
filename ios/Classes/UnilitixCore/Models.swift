// VENDORED from UnilitixCore 0.7.0 (Models.swift) by scripts/sync-ios-core.sh.
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
    /// cannot represent are stored as their description.
    public init(any value: Any?) {
        guard let value = value else { self = .null; return }
        switch value {
        case let v as JSONValue: self = v
        case let v as String: self = .string(v)
        case let v as NSNumber:
            if CFGetTypeID(v) == CFBooleanGetTypeID() {
                self = .bool(v.boolValue)
            } else if CFNumberIsFloatType(v) {
                self = .number(v.doubleValue)
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
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
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
    var networkAtCapture: String?

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
    var events: [IngestEvent]
}

/// `IdentifyRequest` in openapi.sdk.json.
struct IdentifyRequest: Encodable {
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

    static func string(from date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return formatter.string(from: date)
    }
}

/// `ScreenshotInitRequest` in openapi.sdk.json: reserve upload slots.
struct ScreenshotInitRequest: Encodable {
    var sessionId: String
    var count: Int
    var ordinals: [Int]
    /// "jpeg" for iOS frames; the API defaults to webp when absent.
    var format: String
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
