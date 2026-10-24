// VENDORED from UnilitixCore 0.7.0 (ThreadSampler.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

#if canImport(Darwin)
import Darwin
import Foundation

/// Reads another thread's call stack from outside it: the app-hang watchdog
/// uses it on the main thread. All the Mach and Mach-O specifics of hang
/// capture are in this file.
///
/// `backtrace(of:)` suspends the thread, reads its registers
/// (`thread_get_state`), walks the frame-pointer chain (arm64 and x86_64
/// keep frame pointers on Apple platforms) and resumes it. While the thread
/// is suspended nothing is allocated and no lock is taken (the thread may
/// hold the malloc or dyld lock): the walk writes into buffers allocated
/// before, and checks every frame pointer against the thread's stack bounds
/// before reading through it. Symbol lookup (`dladdr`) happens after the
/// thread runs again.
enum ThreadSampler {
    static let maxFrames = 64

    /// A thread to sample: its Mach port and stack bounds.
    struct Target {
        let thread: thread_t
        /// Lowest and highest address of its stack.
        let stackLow: UInt
        let stackHigh: UInt

        /// The calling thread, to be sampled later from another thread.
        static func current() -> Target {
            let p = pthread_self()
            let high = UInt(bitPattern: pthread_get_stackaddr_np(p))
            let size = UInt(pthread_get_stacksize_np(p))
            return Target(thread: pthread_mach_thread_np(p), stackLow: high > size ? high - size : 0,
                          stackHigh: high)
        }
    }

    /// The return addresses on `target`'s stack, innermost first (the first
    /// is where it is executing). At most `maxFrames`. Empty when the thread
    /// cannot be read, or is the calling thread.
    static func backtrace(of target: Target, maxFrames: Int = ThreadSampler.maxFrames) -> [UInt] {
        guard maxFrames >= 3, target.thread != pthread_mach_thread_np(pthread_self()) else { return [] }
        let frames = UnsafeMutablePointer<UInt>.allocate(capacity: maxFrames)
        frames.initialize(repeating: 0, count: maxFrames)
        defer { frames.deallocate() }
        let registers = UnsafeMutableRawPointer.allocate(byteCount: Registers.bytes, alignment: 16)
        registers.initializeMemory(as: UInt8.self, repeating: 0, count: Registers.bytes)
        defer { registers.deallocate() }
        let state = registers.bindMemory(to: natural_t.self, capacity: Registers.bytes / MemoryLayout<natural_t>.size)

        guard thread_suspend(target.thread) == KERN_SUCCESS else { return [] }
        let n = walk(target, state, UnsafeRawPointer(registers), frames, maxFrames)
        thread_resume(target.thread)
        guard n >= 2 else { return [] }

        // frames[0] is the PC, frames[1] the caller candidate (arm64: the
        // link register; x86_64: the word at the stack pointer), then the
        // frame-pointer chain. The candidate is the caller when the thread
        // stopped in a function that has not set up its frame (a system call
        // stub, typically, where a hung main thread waits). Elsewhere it is
        // stale: the same as the first chain entry, or an address inside
        // the current function.
        let pc = frames[0]
        let candidate = frames[1]
        let chain = Array(UnsafeBufferPointer(start: frames + 2, count: n - 2))
        var out = [pc]
        if candidate != 0, candidate != pc, candidate != chain.first, !sameFunction(pc, candidate &- 1) {
            out.append(candidate)
        }
        out.append(contentsOf: chain)
        return Array(out.prefix(maxFrames))
    }

    /// Reads the registers and walks the frame chain into `out`; returns the
    /// count written (0 when the registers could not be read). Runs while
    /// the target is suspended: no allocation, no locks, no lazy globals.
    private static func walk(_ target: Target, _ state: UnsafeMutablePointer<natural_t>,
                             _ registers: UnsafeRawPointer,
                             _ out: UnsafeMutablePointer<UInt>, _ capacity: Int) -> Int {
        #if arch(arm64) || arch(x86_64)
        var count = mach_msg_type_number_t(Registers.count)
        guard thread_get_state(target.thread, Registers.flavor, state, &count) == KERN_SUCCESS else { return 0 }
        let pc = strip(register(registers, Registers.pc))
        guard pc != 0 else { return 0 }
        out[0] = pc
        #if arch(arm64)
        out[1] = strip(register(registers, Registers.lr))
        #else
        let sp = register(registers, Registers.sp)
        if sp >= target.stackLow, sp < target.stackHigh, target.stackHigh - sp >= 8, sp & 7 == 0,
           let top = UnsafePointer<UInt>(bitPattern: sp) {
            out[1] = top.pointee
        } else {
            out[1] = 0
        }
        #endif
        var n = 2
        var fp = register(registers, Registers.fp)
        var previous: UInt = 0
        while n < capacity {
            // A frame record is [previous fp, return address], 16 bytes, on
            // this thread's stack, above the one before it.
            guard fp > previous, fp >= target.stackLow, fp < target.stackHigh,
                  target.stackHigh - fp >= 16, fp & 7 == 0,
                  let record = UnsafePointer<UInt>(bitPattern: fp) else { break }
            let ret = strip(record[1])
            if ret == 0 { break }
            out[n] = ret
            n += 1
            previous = fp
            fp = record[0]
        }
        return n
        #else
        return 0
        #endif
    }

    /// The 64-bit register at word `index` of a `thread_get_state` buffer.
    @inline(__always)
    private static func register(_ registers: UnsafeRawPointer, _ index: Int) -> UInt {
        UInt(registers.load(fromByteOffset: index * 8, as: UInt64.self))
    }

    /// `thread_get_state` layouts, as indexes of 64-bit words. Computed
    /// properties so the walk never runs a lazy initialiser.
    private enum Registers {
        /// Size of the register buffer: room for either layout.
        static var bytes: Int { 512 }
        #if arch(arm64)
        /// ARM_THREAD_STATE64: x0–x28, fp, lr, sp, pc, cpsr + flags (272 bytes).
        static var flavor: thread_state_flavor_t { 6 }
        /// ARM_THREAD_STATE64_COUNT, in natural_t (32-bit) units.
        static var count: Int { 68 }
        static var fp: Int { 29 }
        static var lr: Int { 30 }
        static var sp: Int { 31 }
        static var pc: Int { 32 }
        #elseif arch(x86_64)
        /// x86_THREAD_STATE64: rax rbx rcx rdx rdi rsi rbp rsp r8–r15 rip
        /// rflags cs fs gs (168 bytes).
        static var flavor: thread_state_flavor_t { 4 }
        /// x86_THREAD_STATE64_COUNT, in natural_t (32-bit) units.
        static var count: Int { 42 }
        static var fp: Int { 6 }
        static var sp: Int { 7 }
        static var pc: Int { 16 }
        #endif
    }

    /// Removes pointer-authentication bits from a code address (arm64e
    /// system code signs saved return addresses). Code is mapped low, so the
    /// mask keeps every real address.
    @inline(__always)
    static func strip(_ address: UInt) -> UInt {
        #if arch(arm64)
        #if os(macOS) || targetEnvironment(macCatalyst) || targetEnvironment(simulator)
        return address & 0x0000_7FFF_FFFF_FFFF
        #else
        return address & 0x0000_000F_FFFF_FFFF
        #endif
        #else
        return address
        #endif
    }

    /// True when both addresses resolve to the same symbol.
    private static func sameFunction(_ a: UInt, _ b: UInt) -> Bool {
        var ia = Dl_info()
        var ib = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: a), &ia) != 0,
              dladdr(UnsafeRawPointer(bitPattern: b), &ib) != 0,
              let sa = ia.dli_saddr, let sb = ib.dli_saddr else { return false }
        return sa == sb
    }

    // MARK: Symbolication

    struct Symbolicated {
        /// One `StackFormat.frame` line per address.
        var stack: String
        /// The images the frames are in, each once, in order of appearance.
        var images: [DebugImage]
    }

    /// Names each address with `dladdr`, as `Thread.callStackSymbols` does:
    /// `Image 0x… symbol + offset`, or `Image 0x… Image + offset` (offset
    /// from the image's header) when the image has no symbol for it, as in a
    /// stripped app binary.
    static func symbolicate(_ addresses: [UInt]) -> Symbolicated {
        var lines: [String] = []
        var images: [DebugImage] = []
        var seen = Set<UInt>()
        for (i, address) in addresses.enumerated() {
            var info = Dl_info()
            // A return address may be the first byte after its function (a
            // call to a function that never returns): look up the call.
            let lookup = i == 0 ? address : address &- 1
            guard dladdr(UnsafeRawPointer(bitPattern: lookup), &info) != 0,
                  let base = info.dli_fbase, let file = info.dli_fname else {
                lines.append(StackFormat.frame(index: i, image: "???", address: address, symbol: "0x0", offset: address))
                continue
            }
            let baseAddress = UInt(bitPattern: base)
            let image = StackFormat.imageName(String(cString: file))
            var symbol = image
            var offset = address &- baseAddress
            if let sname = info.dli_sname, let saddr = info.dli_saddr {
                let name = String(cString: sname)
                // The Mach-O header symbol is what a stripped binary resolves to.
                if !name.isEmpty, name != "_mh_execute_header", name != "__mh_execute_header" {
                    symbol = name
                    offset = address &- UInt(bitPattern: saddr)
                }
            }
            lines.append(StackFormat.frame(index: i, image: image, address: address, symbol: symbol, offset: offset))
            if seen.insert(baseAddress).inserted, let img = debugImage(header: UnsafeRawPointer(base), name: image) {
                images.append(img)
            }
        }
        return Symbolicated(stack: lines.joined(separator: "\n"), images: images)
    }

    /// The image whose 64-bit Mach-O header is at `header`, with its LC_UUID;
    /// nil when it is not one or has no UUID.
    /// (Mach-O parsing shared with `BinaryImages`.)
    static func debugImage(header: UnsafeRawPointer, name: String) -> DebugImage? {
        guard let h = BinaryImages.parse(header: header), let bytes = h.uuid,
              let uuid = DebugImage.formatUUID(bytes) else { return nil }
        return DebugImage(name: name, uuid: uuid, loadAddress: DebugImage.formatAddress(UInt(bitPattern: header)),
                          arch: DebugImage.archName(cpuType: h.cpuType, cpuSubtype: h.cpuSubtype))
    }

    // MARK: Debugger

    /// True when a debugger is attached (P_TRACED): a thread stopped at a
    /// breakpoint is not a hang.
    static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = mib.withUnsafeMutableBufferPointer { buffer in
            sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0)
        }
        return result == 0 && (info.kp_proc.p_flag & P_TRACED) != 0
    }
}
#endif
