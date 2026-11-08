// VENDORED from UnilitixCore 0.8.0 (Transport.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Compression)
import Compression
#endif

/// HTTP for the SDK. A protocol so tests can script responses.
protocol Transport {
    /// POSTs JSON to the ingest API. `status` is nil when no response arrived
    /// (DNS, TLS, timeout, offline).
    func post(_ path: String, body: Data,
              completion: @escaping (_ status: Int?, _ headers: [String: String]) -> Void)
    /// Like `post`, and also hands back the response body (nil without a response).
    func postForResponse(_ path: String, body: Data,
                         completion: @escaping (_ status: Int?, _ headers: [String: String], _ body: Data?) -> Void)
    /// PUTs bytes to an absolute URL, such as a presigned storage URL. The URL
    /// carries its own authorisation, so no API key is sent.
    func put(_ url: URL, body: Data, contentType: String,
             completion: @escaping (_ status: Int?) -> Void)
}

final class URLSessionTransport: Transport {
    private let baseURL: String
    private let apiKey: String
    private let session: URLSession
    /// Separate session for presigned uploads: no API key, longer timeout.
    private let uploads: URLSession

    /// Budget for one screenshot PUT to storage.
    static let uploadTimeoutSeconds: TimeInterval = 60

    init(baseURL: String, apiKey: String) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = TimeInterval(SdkContract.requestTimeoutSeconds)
        cfg.timeoutIntervalForResource = TimeInterval(SdkContract.requestTimeoutSeconds)
        cfg.waitsForConnectivity = false
        // Never share the app's cookie jar with the ingest API.
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        session = URLSession(configuration: cfg)
        let up = URLSessionConfiguration.default
        up.timeoutIntervalForRequest = URLSessionTransport.uploadTimeoutSeconds
        up.timeoutIntervalForResource = URLSessionTransport.uploadTimeoutSeconds
        up.waitsForConnectivity = false
        up.httpCookieAcceptPolicy = .never
        up.httpShouldSetCookies = false
        up.httpCookieStorage = nil
        uploads = URLSession(configuration: up)
    }

    func post(_ path: String, body: Data,
              completion: @escaping (Int?, [String: String]) -> Void) {
        postForResponse(path, body: body) { status, headers, _ in completion(status, headers) }
    }

    func postForResponse(_ path: String, body: Data,
                         completion: @escaping (Int?, [String: String], Data?) -> Void) {
        guard let url = URL(string: baseURL + path) else {
            completion(400, [:], nil)  // a malformed apiUrl can never succeed
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // gzip when it pays off (0.8.0); the API inflates `Content-Encoding:
        // gzip` bodies. Uncompressed when compression is unavailable or fails.
        if body.count >= Gzip.minimumBytes, let gz = Gzip.compress(body) {
            req.httpBody = gz
            req.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        } else {
            req.httpBody = body
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: SdkContract.apiKeyHeader)
        req.setValue(UnilitixVersion.userAgent, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: req) { data, response, _ in
            guard let http = response as? HTTPURLResponse else {
                completion(nil, [:], nil)
                return
            }
            completion(http.statusCode, URLSessionTransport.headers(of: http), data)
        }.resume()
    }

    func put(_ url: URL, body: Data, contentType: String,
             completion: @escaping (Int?) -> Void) {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        // Part of the presigned signature: must match what the API signed.
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        uploads.uploadTask(with: req, from: body) { _, response, _ in
            completion((response as? HTTPURLResponse)?.statusCode)
        }.resume()
    }

    private static func headers(of http: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String { headers[k] = "\(v)" }
        }
        return headers
    }
}

public enum UnilitixVersion {
    /// This package's version.
    public static let current = "0.8.0"

    private static let lock = NSLock()
    private static var _reported = current
    private static var _platform = "iOS"
    private static var _wrapper: (name: String, version: String)?

    /// What the SDK reports to the API (session `sdkVersion`, User-Agent).
    /// Wrappers that embed UnilitixCore, such as React Native, set their own
    /// (directly, or with `setWrapper`).
    static var reported: String {
        get { lock.lock(); defer { lock.unlock() }; return _reported }
        set { lock.lock(); _reported = newValue; lock.unlock() }
    }

    static var userAgentPlatform: String {
        get { lock.lock(); defer { lock.unlock() }; return _platform }
        set { lock.lock(); _platform = newValue; lock.unlock() }
    }

    /// `Unilitix.setWrapper`: the wrapper's name and version become the
    /// reported platform and version, and `sessionData` names both SDKs.
    static func setWrapper(name: String, version: String) {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        let v = String(version.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !n.isEmpty else { return }
        lock.lock()
        _wrapper = (n, v)
        if !v.isEmpty { _reported = v }
        _platform = platformToken(n)
        lock.unlock()
    }

    /// Back to the native SDK's own values (tests).
    static func clearWrapper() {
        lock.lock()
        _wrapper = nil
        _reported = current
        _platform = "iOS"
        lock.unlock()
    }

    /// "flutter" → "Flutter", "react-native" → "ReactNative".
    static func platformToken(_ name: String) -> String {
        let parts = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let token = parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return token.isEmpty ? "iOS" : token
    }

    /// "Unilitix-iOS/0.8.0", or with a wrapper
    /// "Unilitix-Flutter/3.0.0 UnilitixCore/0.8.0".
    static var userAgent: String {
        lock.lock(); defer { lock.unlock() }
        let base = "Unilitix-\(_platform)/\(_reported)"
        return _wrapper == nil && _reported == current ? base : base + " UnilitixCore/\(current)"
    }

    /// The session's `sessionData` when a wrapper is set:
    /// `{"wrapper": name, "wrapperVersion": version, "coreVersion": current}`.
    static var sessionData: [String: JSONValue]? {
        lock.lock(); defer { lock.unlock() }
        guard let w = _wrapper else { return nil }
        return ["wrapper": .string(w.name), "wrapperVersion": .string(w.version), "coreVersion": .string(current)]
    }
}

/// gzip (RFC 1952) with the Compression framework's raw DEFLATE (iOS 9+,
/// macOS 10.11+) and a CRC-32 computed here. Nil when unavailable.
enum Gzip {
    /// Smaller bodies are sent as they are.
    static let minimumBytes = 1024

    static func compress(_ data: Data) -> Data? {
        #if canImport(Compression)
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 16 + 1024
        var deflated = Data(count: capacity)
        let written: Int = deflated.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(d, capacity, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])
        out.append(deflated.prefix(written))
        appendLE(&out, crc32(data))
        appendLE(&out, UInt32(truncatingIfNeeded: data.count))
        return out
        #else
        return nil
        #endif
    }

    private static func appendLE(_ d: inout Data, _ v: UInt32) {
        d.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)])
    }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xffffffff
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { c = table[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        }
        return c ^ 0xffffffff
    }
}

/// Static facts about the device and app for the session record.
struct DeviceInfo {
    var os = "iOS"
    var osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    var deviceModel = DeviceInfo.machine()
    var deviceType = "phone"
    var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    var buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    var packageName = Bundle.main.bundleIdentifier ?? ""
    /// Screen size in points (the unit tap coordinates use) and its scale.
    var screenWidth: Int?
    var screenHeight: Int?
    var screenDensity: Double?
    var locale = Locale.current.identifier
    var timezone = TimeZone.current.identifier

    static func current() -> DeviceInfo {
        var info = DeviceInfo()
        #if canImport(UIKit) && !os(watchOS)
        let device = UIDevice.current
        info.os = device.systemName
        info.osVersion = device.systemVersion
        info.deviceType = device.userInterfaceIdiom == .pad ? "tablet" : "phone"
        let screen = UIScreen.main
        info.screenWidth = Int(screen.bounds.width)
        info.screenHeight = Int(screen.bounds.height)
        info.screenDensity = Double(screen.scale)
        #elseif os(macOS)
        info.os = "macOS"
        info.deviceType = "desktop"
        #endif
        return info
    }

    /// Hardware identifier such as "iPhone15,2".
    static func machine() -> String {
        var sys = utsname()
        uname(&sys)
        let mirror = Mirror(reflecting: sys.machine)
        return mirror.children.reduce(into: "") { s, child in
            if let byte = child.value as? Int8, byte != 0 { s.append(Character(UnicodeScalar(UInt8(byte)))) }
        }
    }
}
