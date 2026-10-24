// VENDORED from UnilitixCore 0.7.0 (BinaryImages.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

#if canImport(Darwin)
import Darwin
import Foundation
import MachO

/// The process's loaded Mach-O images (app, embedded frameworks, system
/// libraries), kept up to date from dyld's add/remove-image callbacks, so a
/// crash only looks addresses up: no image is enumerated or parsed then.
///
/// One table, two views:
/// - `image(containing:)`, `debugImages(returnAddresses:)`,
///   `debugImages(stack:)`: ordinary code (the uncaught-exception handler,
///   handled errors, the hang sampler, the next launch), under a lock.
/// - The crash table (`CrashEntry`): fixed-capacity memory allocated once,
///   holding each image's address range and its `metadata.debugImages` JSON
///   object rendered in advance. The signal handler (`SignalBacktrace`) reads
///   it without a lock, allocation or formatting; entries are complete before
///   `crashCount` counts them, and are never moved or freed.
enum BinaryImages {
    /// One loaded image.
    struct Image: Equatable {
        /// Address of its Mach-O header (its load address).
        let start: UInt
        /// `start` + its `__TEXT` segment size: its code is in [start, end).
        let end: UInt
        /// Name as printed in stack frames (`StackFormat.imageName`).
        let name: String
        /// LC_UUID, upper case with dashes; nil when it has none.
        let uuid: String?
        let arch: String?

        /// The image as `metadata.debugImages` lists it; nil without a UUID
        /// (the server matches dSYMs by UUID).
        var debugImage: DebugImage? {
            guard let u = uuid else { return nil }
            return DebugImage(name: name, uuid: u, loadAddress: DebugImage.formatAddress(start), arch: arch)
        }

        func contains(_ address: UInt) -> Bool { address >= start && address < end }
    }

    /// What `parse(header:)` reads from a mapped 64-bit Mach-O header.
    struct Header {
        var uuid: [UInt8]?
        var cpuType: Int32
        var cpuSubtype: Int32
        /// `__TEXT` vmsize (0 when there is no `__TEXT` segment).
        var textSize: UInt
    }

    /// Reads the LC_UUID, CPU type and `__TEXT` size of the 64-bit Mach-O
    /// image whose header is at `header`; nil when it is not one.
    static func parse(header: UnsafeRawPointer) -> Header? {
        // mach_header_64: magic, cputype, cpusubtype, filetype, ncmds,
        // sizeofcmds, flags, reserved (32 bytes), then the load commands.
        guard header.load(as: UInt32.self) == 0xFEED_FACF else { return nil }  // MH_MAGIC_64
        var out = Header(uuid: nil,
                         cpuType: header.load(fromByteOffset: 4, as: Int32.self),
                         cpuSubtype: header.load(fromByteOffset: 8, as: Int32.self),
                         textSize: 0)
        let ncmds = header.load(fromByteOffset: 16, as: UInt32.self)
        let sizeofcmds = header.load(fromByteOffset: 20, as: UInt32.self)
        var command = header + 32
        let end = command + Int(sizeofcmds)
        var i: UInt32 = 0
        while i < ncmds, command + 8 <= end {
            let cmd = command.load(as: UInt32.self)
            let size = Int(command.load(fromByteOffset: 4, as: UInt32.self))
            guard size >= 8, command + size <= end else { break }
            if cmd == 0x1B, size >= 24 {  // LC_UUID: cmd, cmdsize, uuid[16]
                out.uuid = (0..<16).map { command.load(fromByteOffset: 8 + $0, as: UInt8.self) }
            } else if cmd == 0x19, size >= 72 {  // LC_SEGMENT_64: cmd, cmdsize, segname[16], vmaddr, vmsize, …
                // "__TEXT" then NULs, read as two words.
                let name0 = command.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
                let name1 = command.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
                if name0 == 0x0000_5458_4554_5F5F, name1 == 0 {  // "__TEXT\0\0" little-endian
                    out.textSize = UInt(command.loadUnaligned(fromByteOffset: 32, as: UInt64.self))
                }
            }
            command += size
            i += 1
        }
        return out
    }

    // MARK: Table

    private static let lock = NSLock()
    /// Sorted by `start`. Under `lock`.
    private static var images: [Image] = []
    private static var registered = false

    /// Starts tracking images (once per process): dyld calls back for every
    /// image already loaded, synchronously, then for each one loaded or
    /// unloaded later. Call before installing crash handlers. Any thread.
    static func install() {
        lock.lock()
        let first = !registered
        registered = true
        lock.unlock()
        guard first else { return }
        CrashTable.allocate()
        _dyld_register_func_for_add_image { header, _ in
            if let h = header { BinaryImages.added(UnsafeRawPointer(h)) }
        }
        _dyld_register_func_for_remove_image { header, _ in
            if let h = header { BinaryImages.removed(UInt(bitPattern: UnsafeRawPointer(h))) }
        }
    }

    static var isInstalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return registered
    }

    /// dyld callback (dyld's lock held: no dlopen here; dladdr is fine, as
    /// dyld's lock is recursive).
    private static func added(_ header: UnsafeRawPointer) {
        guard let image = describe(header: header) else { return }
        lock.lock()
        defer { lock.unlock() }
        let start = image.start
        var lo = 0, hi = images.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if images[mid].start < start { lo = mid + 1 } else { hi = mid }
        }
        if lo < images.count, images[lo].start == start { return }
        images.insert(image, at: lo)
        CrashTable.append(image)
    }

    private static func removed(_ start: UInt) {
        lock.lock()
        defer { lock.unlock() }
        images.removeAll { $0.start == start }
        CrashTable.remove(start: start)
    }

    /// The image at `header`: name from dladdr, UUID, arch and `__TEXT` size
    /// from its load commands.
    static func describe(header: UnsafeRawPointer) -> Image? {
        guard let h = parse(header: header), h.textSize > 0 else { return nil }
        var info = Dl_info()
        var name = "???"
        if dladdr(header, &info) != 0, let file = info.dli_fname {
            name = StackFormat.imageName(String(cString: file))
        }
        let start = UInt(bitPattern: header)
        return Image(start: start, end: start &+ h.textSize, name: name,
                     uuid: h.uuid.flatMap(DebugImage.formatUUID),
                     arch: DebugImage.archName(cpuType: h.cpuType, cpuSubtype: h.cpuSubtype))
    }

    // MARK: Lookup

    /// The loaded image whose code contains `address`.
    static func image(containing address: UInt) -> Image? {
        install()
        lock.lock()
        defer { lock.unlock() }
        var lo = 0, hi = images.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if images[mid].start <= address { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return nil }
        let candidate = images[lo - 1]
        return candidate.contains(address) ? candidate : nil
    }

    /// The loaded image with this LC_UUID (any case), if any.
    static func image(uuid: String) -> Image? {
        install()
        let wanted = uuid.uppercased()
        lock.lock()
        defer { lock.unlock() }
        return images.first { $0.uuid == wanted }
    }

    /// The images of a backtrace's addresses, each once, in order of first
    /// appearance (`metadata.debugImages`). Return addresses are looked up
    /// one byte back (a call to a function that never returns may be the
    /// last instruction of its image); with `firstIsPC` the first address is
    /// where the thread was executing and is used as is. PAC bits are
    /// stripped first.
    static func debugImages(returnAddresses addresses: [UInt], firstIsPC: Bool = false) -> [DebugImage] {
        var out: [DebugImage] = []
        var seen = Set<UInt>()
        for (i, raw) in addresses.enumerated() {
            let address = ThreadSampler.strip(raw)
            guard address != 0 else { continue }
            let lookup = (i == 0 && firstIsPC) ? address : address &- 1
            guard let image = image(containing: lookup), seen.insert(image.start).inserted,
                  let d = image.debugImage else { continue }
            out.append(d)
        }
        return out
    }

    /// The images of a stack trace's text, in this process: for each Apple
    /// frame (`2   Shop   0x00000001043a81c4 …`), the loaded image of that
    /// name whose code contains the frame's address. Frames recorded in
    /// another process (different addresses) match nothing.
    static func debugImages(stack: String) -> [DebugImage] {
        var out: [DebugImage] = []
        var seen = Set<UInt>()
        for line in stack.split(separator: "\n") {
            guard let m = appleFrame.match(line.trimmingCharacters(in: .whitespaces)),
                  let name = m[1], let hex = m[2], let address = UInt(hex, radix: 16), address != 0,
                  let image = image(containing: address &- 1) ?? image(containing: address),
                  image.name == name, seen.insert(image.start).inserted,
                  let d = image.debugImage else { continue }
            out.append(d)
        }
        return out
    }

    private static let appleFrame = Pattern(#"^\d+\s+(\S+)\s+0x([0-9a-fA-F]+)\s.*$"#)

    /// The symbol containing `offset` in the loaded image with LC_UUID
    /// `uuid`: its name and its offset from the image's header. Used on the
    /// next launch to name a crashed process's frames when this process has
    /// the same binary loaded (same build, same OS): the frame text then
    /// reads like `callStackSymbols`. Nil when that image is not loaded or
    /// has no symbol there (a stripped app binary often has none; the
    /// server symbolicates it from the dSYM).
    static func symbol(uuid: String, offset: UInt) -> CrashFile.Symbol? {
        guard let image = image(uuid: uuid), offset < image.end &- image.start else { return nil }
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: image.start &+ offset), &info) != 0,
              let base = info.dli_fbase, UInt(bitPattern: base) == image.start,
              let sname = info.dli_sname, let saddr = info.dli_saddr else { return nil }
        let name = String(cString: sname)
        // The Mach-O header symbol is what a stripped binary resolves to.
        guard !name.isEmpty, name != "_mh_execute_header", name != "__mh_execute_header" else { return nil }
        return CrashFile.Symbol(name: name, start: UInt(bitPattern: saddr) &- image.start)
    }

    // MARK: Crash table

    /// One image as the signal handler reads it.
    struct CrashEntry {
        /// 0 once the image was unloaded.
        var start: UInt
        var end: UInt
        /// `{"name":…,"uuid":…,"loadAddress":…,"arch":…,"size":…}`, never freed.
        var json: UnsafeMutablePointer<UInt8>?
        var length: Int
    }

    /// The handler's view. Written only under `BinaryImages.lock`; read by the
    /// signal handler without it.
    enum CrashTable {
        /// More than any app loads (typically 300–900 images, most of them
        /// system libraries); images past it are left out (the app's own load
        /// first).
        static let capacity = 4096
        private(set) static var entries: UnsafeMutablePointer<CrashEntry>?
        /// Entries [0, count) are complete.
        private(set) static var count = 0

        static func allocate() {
            guard entries == nil else { return }
            let p = UnsafeMutablePointer<CrashEntry>.allocate(capacity: capacity)
            p.initialize(repeating: CrashEntry(start: 0, end: 0, json: nil, length: 0), count: capacity)
            entries = p
            count = 0
        }

        /// Under `BinaryImages.lock`.
        fileprivate static func append(_ image: Image) {
            guard let e = entries, count < capacity else { return }
            let bytes = Array(json(image).utf8)
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
            buffer.initialize(from: bytes, count: bytes.count)
            e[count] = CrashEntry(start: image.start, end: image.end, json: buffer, length: bytes.count)
            count += 1  // published after the entry is complete
        }

        /// Under `BinaryImages.lock`. The entry stays (its JSON may be being
        /// written); it just no longer matches any address.
        fileprivate static func remove(start: UInt) {
            guard let e = entries else { return }
            for i in 0..<count where e[i].start == start {
                e[i].end = 0
                e[i].start = 0
            }
        }

        /// The crash-file form of an image: `metadata.debugImages` plus
        /// `size` (the `__TEXT` size, to map the crashed process's addresses
        /// to it on the next launch). `uuid` is "" when it has none.
        static func json(_ image: Image) -> String {
            var s = "{\"name\":" + CrashFile.jsonString(image.name)
            s += ",\"uuid\":\"" + (image.uuid ?? "") + "\""
            s += ",\"loadAddress\":\"" + DebugImage.formatAddress(image.start) + "\""
            if let a = image.arch { s += ",\"arch\":\"" + a + "\"" }
            s += ",\"size\":" + String(image.end &- image.start) + "}"
            return s
        }

        /// The index of the entry whose code contains `address`, or -1.
        /// Async-signal-safe: loads only.
        static func index(containing address: UInt) -> Int {
            guard let e = entries else { return -1 }
            let n = count
            var i = 0
            while i < n {
                let s = e[i].start
                if s != 0, address >= s, address < e[i].end { return i }
                i += 1
            }
            return -1
        }
    }
}
#endif
