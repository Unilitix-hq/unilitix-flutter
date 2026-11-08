// VENDORED from UnilitixCore 0.8.0 (Fingerprint.swift) by scripts/sync-ios-core.sh.
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

    /// The fingerprint of an error of `exceptionType` with `stack`.
    /// A native crash type (`SIGNAL` or `SIGNAL:<n>`, contract 1.4.0) is
    /// grouped by `native(_:stack:)` instead: only the app's own frames count.
    public static func of(_ exceptionType: String, stack: String?) -> String {
        if isSignalType(exceptionType) { return native(exceptionType, stack: stack) }
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

    // MARK: Native crashes (contract 1.4.0, native.go in the api repo)

    /// True for `SIGNAL` and `SIGNAL:<n>`.
    public static func isSignalType(_ type: String) -> Bool {
        signalType.match(type) != nil
    }

    /// The fingerprint type of a native crash event: `SIGNAL:<n>` from
    /// `exceptionType` `SIGNAL` and `metadata.signal` n (nil or n <= 0:
    /// `SIGNAL`); a type that already is `SIGNAL:<n>` is kept.
    public static func signalFingerprintType(_ exceptionType: String, signal: Int?) -> String {
        if let m = signalType.match(exceptionType), m.count > 1, m[1] != nil { return exceptionType }
        if let n = signal, n > 0 { return "SIGNAL:\(n)" }
        return "SIGNAL"
    }

    /// `signalType` and the first `SdkContract.fingerprintFrames` frames of
    /// `stack` that are the app's own code (`nativeFrame`; frames of
    /// system, runtime, engine and SDK images are skipped). With no app
    /// frame this is the 1.3 value, `of("SIGNAL:<n>", stack: nil)`.
    public static func native(_ signalType: String, stack: String?) -> String {
        fnv1a64(([signalType] + nativeAppFrames(stack)).joined(separator: "|"))
    }

    /// The first `SdkContract.fingerprintFrames` app frames of a native
    /// stack, normalised.
    static func nativeAppFrames(_ stack: String?) -> [String] {
        var out: [String] = []
        guard let stack = stack else { return out }
        for raw in stack.components(separatedBy: "\n") {
            if out.count == SdkContract.fingerprintFrames { break }
            guard let f = nativeFrame(raw), !f.system else { continue }
            out.append(f.frame)
        }
        return out
    }

    /// One line of a native stack in fingerprint form, and whether it is
    /// system code; nil when the line is not a frame. Rules:
    ///
    ///     tombstone   "#01 pc 0001a1f0  /data/app/…/libshop.so (Java_pay+40) (BuildId: 9f)" -> "libshop.so Java_pay"
    ///     no symbol   "#00 pc 000000000001a2b4  /data/app/…/libshop.so (BuildId: 9f)"      -> "libshop.so+0x1a2b4"
    ///     Apple       "3   Shop  0x1043a81c4 -[Cart pay:] + 52"   -> "Shop -[Cart pay:]"
    ///     Apple       "3   Shop  0x1043a81c4 Shop + 70084"        -> "Shop+70084"
    ///     Dart AOT    "#00 abs 0000007a1b2c3d4e virt 00000000002c3d4e …" -> "virt:00000000002c3d4e" (app)
    static func nativeFrame(_ raw: String) -> (frame: String, system: Bool)? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return nil }
        if let m = tombstoneFrame.match(line), let pcHex = m[1], let tail = m[2] {
            guard let pc = UInt64(pcHex, radix: 16) else { return nil }
            var rest = tombBuildId.replace(tail, with: "")
            rest = tombOffset.replace(rest, with: "")
            var file = rest
            var symbol = ""
            if let open = rest.range(of: " ("), rest.hasSuffix(")") {
                file = String(rest[..<open.lowerBound])
                symbol = String(rest[open.upperBound..<rest.index(before: rest.endIndex)])
            }
            file = file.trimmingCharacters(in: .whitespaces)
            var image = file
            if let bang = image.range(of: "!", options: .backwards) {
                image = String(image[bang.upperBound...])
            }
            image = image.isEmpty ? "." : (image as NSString).lastPathComponent
            symbol = symbolOffset.replace(symbol.trimmingCharacters(in: .whitespaces), with: "")
                .trimmingCharacters(in: .whitespaces)
            let frame = symbol.isEmpty ? image + "+0x" + String(pc, radix: 16) : image + " " + symbol
            return (frame, isNativeSystemImage(image, path: file))
        }
        if let m = appleFrame.match(line), let image = m[1], let sym = m[2] {
            let symbol = sym.trimmingCharacters(in: .whitespaces)
            let frame: String
            if symbol == image, let offset = m[3] {
                frame = image + "+" + offset
            } else {
                frame = image + " " + symbol
            }
            return (frame, isNativeSystemImage(image, path: ""))
        }
        if let m = dartFrame.match(line), let frame = m[1], let v = dartVirt.firstMatch(frame), let addr = v[1] {
            return ("virt:" + addr, false)
        }
        return nil
    }

    /// True when a frame in `image` (mapped from `path`, "" when unknown)
    /// is outside the app's own code (`SdkContract.nativeSystemImages`,
    /// `SdkContract.nativeSystemPathPrefixes`).
    static func isNativeSystemImage(_ image: String, path: String) -> Bool {
        if !path.isEmpty, SdkContract.nativeSystemPathPrefixes.contains(where: { path.hasPrefix($0) }) {
            return true
        }
        if image.isEmpty || image == "???" || image.hasPrefix("[") || image.hasPrefix("<") { return true }
        for name in SdkContract.nativeSystemImages {
            if name.hasSuffix("*") {
                if image.hasPrefix(String(name.dropLast())) { return true }
            } else if image == name {
                return true
            }
        }
        return false
    }

    private static let signalType = Pattern(#"^SIGNAL(?::(\d+))?$"#)
    private static let tombstoneFrame = Pattern(#"^(?:native:\s+)?#\d+\s+pc\s+([0-9a-fA-F]{1,16})\s+(.*?)\s*$"#)
    private static let tombBuildId = Pattern(#"\s*\(BuildId:\s*[0-9a-fA-F]+\)$"#)
    private static let tombOffset = Pattern(#"\s*\(offset 0x[0-9a-fA-F]+\)"#)
    private static let symbolOffset = Pattern(#"\+(?:0x[0-9a-fA-F]+|\d+)$"#)

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
