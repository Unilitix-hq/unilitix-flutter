// VENDORED from UnilitixCore 0.4.1 (Fingerprint.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation

/// A stable id for "this bug", sent as `metadata.fingerprint` on CRASH and
/// EXCEPTION so the dashboard counts one bug once across devices.
///
/// Port of the reference implementation in the api repo
/// (`internal/sdkcontract/fingerprint.go`): the exception type plus the first
/// `SdkContract.fingerprintFrames` normalised frames, hashed with two 32-bit
/// FNV-1a passes. `SdkContract.fingerprintVectors` pins the output.
public enum Fingerprint {

    public static func of(_ exceptionType: String, stack: String?) -> String {
        var parts = [exceptionType]
        if let stack = stack {
            for raw in stack.components(separatedBy: "\n") {
                if parts.count - 1 == SdkContract.fingerprintFrames { break }
                if let frame = normalise(raw) { parts.append(frame) }
            }
        }
        return fnv1a64(parts.joined(separator: "|"))
    }

    /// One stack line in fingerprint form, or nil when it is not a frame.
    /// Rules (first match wins), as in the reference implementation:
    ///
    ///     Apple    "2   Shop  0x1043a81c4 -[Cart pay:] + 52"  -> "Shop -[Cart pay:]"
    ///              "2   Shop  0x1043a81c4 Shop + 70084"       -> "Shop+70084"
    ///     Dart     "#0  Foo.bar (package:a/b.dart:12:5)"      -> "Foo.bar (package:a/b.dart)"
    ///     Dart AOT "#00 abs 0000 virt 1a2b _kDart..."          -> "virt:1a2b"
    ///     JS       "at foo (index.bundle:1:2345)"             -> "foo (index.bundle)"
    ///     JVM      "at a.B.c(B.kt:12)"                        -> "a.B.c(B.kt)"
    ///     bare     "at foo:1:2"                               -> "foo"
    public static func normalise(_ raw: String) -> String? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return nil }

        if let m = appleFrame.match(line), let image = m[1], let sym = m[2] {
            let symbol = sym.trimmingCharacters(in: .whitespaces)
            if symbol == image, let offset = m[3] {
                return image + "+" + offset
            }
            return image + " " + symbol
        }
        if let m = dartFrame.match(line), let frame = m[1] {
            if let v = dartVirt.firstMatch(frame), let addr = v[1] {
                return "virt:" + addr
            }
            let noLine = dartLine.replace(frame, with: ")")
            if noLine.hasPrefix("<asynchronous suspension>") { return nil }
            return spaces.replace(noLine, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let m = jsFrame.match(line), let fn = m[1], let file = m[2] {
            return fn + " (" + file + ")"
        }
        if let m = jvmFrame.match(line), let fn = m[1], let file = m[2] {
            return fn + "(" + file + ")"
        }
        if line.hasPrefix("at ") {
            let rest = String(line.dropFirst(3))
            return trailLine.replace(rest, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    // Patterns are copied verbatim from fingerprint.go.
    private static let appleFrame = Pattern(#"^\d+\s+(\S+)\s+0x[0-9a-fA-F]+\s+(.+?)(?:\s+\+\s+(\d+))?$"#)
    private static let dartFrame = Pattern(#"^#\d+\s+(.*)$"#)
    private static let dartVirt = Pattern(#"virt\s+([0-9a-f]+)"#)
    private static let dartLine = Pattern(#":\d+(:\d+)?\)"#)
    private static let spaces = Pattern(#"\s+"#)
    private static let jsFrame = Pattern(#"^at\s+(.*?)\s*\((.*?)(?::\d+)+\)$"#)
    private static let jvmFrame = Pattern(#"^at\s+(.*?)\(([^:()]+)(?::\d+)?\)$"#)
    private static let trailLine = Pattern(#":\d+(:\d+)?$"#)

    static func fnv1a64(_ s: String) -> String {
        let bytes = Array(s.utf8)
        let a = fnv1a32(bytes, 0x811c9dc5)
        let b = fnv1a32(bytes, 0x811c9dc5 ^ 0x5bd1e995)
        return String(format: "%08x%08x", a, b)
    }

    private static func fnv1a32(_ bytes: [UInt8], _ seed: UInt32) -> UInt32 {
        var h = seed
        for byte in bytes {
            h ^= UInt32(byte)
            h = h &* 16777619
        }
        return h
    }
}

/// Small NSRegularExpression wrapper (Swift's `Regex` needs iOS 16).
final class Pattern {
    private let re: NSRegularExpression

    init(_ pattern: String) {
        // Patterns are compile-time constants; a bad one is a programming error.
        re = try! NSRegularExpression(pattern: pattern)
    }

    /// Capture groups of a match covering the whole string, or nil.
    func match(_ s: String) -> [String?]? {
        guard let groups = firstMatch(s), let whole = groups[0], whole == s else { return nil }
        return groups
    }

    /// Capture groups of the first match anywhere in the string, or nil.
    func firstMatch(_ s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    func replace(_ s: String, with template: String) -> String {
        let ns = s as NSString
        return re.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: ns.length),
            withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }
}
