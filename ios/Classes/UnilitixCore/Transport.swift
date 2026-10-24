// VENDORED from UnilitixCore 0.6.0 (Transport.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation
#if canImport(UIKit)
import UIKit
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
        session = URLSession(configuration: cfg)
        let up = URLSessionConfiguration.default
        up.timeoutIntervalForRequest = URLSessionTransport.uploadTimeoutSeconds
        up.timeoutIntervalForResource = URLSessionTransport.uploadTimeoutSeconds
        up.waitsForConnectivity = false
        up.httpCookieAcceptPolicy = .never
        up.httpShouldSetCookies = false
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
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: SdkContract.apiKeyHeader)
        req.setValue("Unilitix-\(UnilitixVersion.userAgentPlatform)/\(UnilitixVersion.reported)",
                     forHTTPHeaderField: "User-Agent")
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
    public static let current = "0.6.0"
    /// What the SDK reports to the API (session `sdkVersion`, User-Agent).
    /// Wrappers that embed UnilitixCore, such as React Native, set their own.
    static var reported = current
    static var userAgentPlatform = "iOS"
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
