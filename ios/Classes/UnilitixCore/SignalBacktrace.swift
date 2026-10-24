// VENDORED from UnilitixCore 0.7.0 (SignalBacktrace.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

#if canImport(Darwin)
import Darwin
import MachO

/// The crashing thread's backtrace, captured inside a fatal-signal handler
/// and appended to `CrashFile`'s signal record. Every ucontext/mcontext
/// detail is in this file.
///
/// Async-signal-safe by construction, as KSCrash and PLCrashReporter do it:
/// - registers come from the handler's `ucontext_t` (SA_SIGINFO), not from
///   any API;
/// - the frame-pointer chain (arm64 and x86_64 keep frame pointers on Apple
///   platforms) is walked with every 16-byte frame record copied by
///   `vm_read_overwrite`, which fails instead of faulting on a bad pointer,
///   after checks that the frame pointer is aligned, at or above the stack
///   pointer, strictly increasing (so a corrupt chain cannot loop) and within
///   `maxStackSpan` of it; at most `maxFrames` frames;
/// - buffers are on the (alternate) signal stack, under 1 KB each, so they
///   never fall back to the heap; output goes straight to write(2);
/// - images come from `BinaryImages.CrashTable`, whose JSON was rendered
///   when each image was loaded: lookup and write only. No malloc, no lock,
///   no Objective-C or Swift runtime calls that allocate.
///
/// The record gains (all optional; readers of the 0.5 format ignore them):
///
///     "frames":["0x1a2b3c4d0",…]        pc first, then return addresses
///     "linkRegister":"0x1a2b3c000"      arm64 only (see CrashFile.backtraceStack)
///     "debugImages":[{"name":…,"uuid":…,"loadAddress":…,"arch":…,"size":…},…]
///
/// Addresses are the crashed process's: the next launch maps them with the
/// images written here, never with its own (ASLR differs per process).
enum SignalBacktrace {
    /// Computed, like every constant the handler reads, so it never runs a
    /// lazy initialiser (swift_once) inside the handler.
    static var maxFrames: Int { 64 }
    /// Frames further than this above the stack pointer are not trusted
    /// (the largest thread stack, the macOS main thread's, is 8 MB).
    static var maxStackSpan: UInt { 8 * 1024 * 1024 }

    struct Registers {
        var pc: UInt
        /// Link register (arm64); 0 on x86_64.
        var lr: UInt
        var fp: UInt
        var sp: UInt
    }

    /// The interrupted thread's registers, from the third argument of an
    /// SA_SIGINFO handler. On Darwin `uc_mcontext` is a pointer to
    /// `__darwin_mcontext64`, whose `__ss` is the thread state.
    static func registers(_ context: UnsafeMutableRawPointer?) -> Registers? {
        guard let context = context else { return nil }
        let uc = context.assumingMemoryBound(to: ucontext_t.self)
        guard let mc = uc.pointee.uc_mcontext else { return nil }
        #if arch(arm64)
        let ss = mc.pointee.__ss
        return Registers(pc: UInt(ss.__pc), lr: UInt(ss.__lr), fp: UInt(ss.__fp), sp: UInt(ss.__sp))
        #elseif arch(x86_64)
        let ss = mc.pointee.__ss
        return Registers(pc: UInt(ss.__rip), lr: 0, fp: UInt(ss.__rbp), sp: UInt(ss.__rsp))
        #else
        return nil
        #endif
    }

    /// Writes `out[0] = pc`, then the return address of each frame record on
    /// the chain from `fp`, PAC bits stripped; returns the count (0 when
    /// `pc` is 0). `sp` 0 means unknown (the chain is then only checked
    /// against its own start). Async-signal-safe.
    static func walk(pc: UInt, fp startFP: UInt, sp: UInt,
                     into out: UnsafeMutablePointer<UInt>, capacity: Int) -> Int {
        let start = ThreadSampler.strip(pc)
        guard capacity > 0, start != 0 else { return 0 }
        out[0] = start
        var n = 1
        let low = sp != 0 ? sp : startFP
        var fp = startFP
        var previous: UInt = 0
        var record: (UInt, UInt) = (0, 0)
        while n < capacity {
            // A frame record is [caller's fp, return address], above the one before it.
            guard fp != 0, fp & 7 == 0, fp >= low, fp > previous, fp &- low < maxStackSpan,
                  readRecord(fp, &record) else { break }
            let ret = ThreadSampler.strip(record.1)
            if ret == 0 { break }
            out[n] = ret
            n += 1
            previous = fp
            fp = record.0
        }
        return n
    }

    /// Copies the 16 bytes at `address` without faulting.
    @inline(__always)
    private static func readRecord(_ address: UInt, _ record: inout (UInt, UInt)) -> Bool {
        withUnsafeMutableBytes(of: &record) { buffer -> Bool in
            var copied: vm_size_t = 0
            let kr = vm_read_overwrite(mach_task_self_, vm_address_t(address), vm_size_t(16),
                                       vm_address_t(UInt(bitPattern: buffer.baseAddress)), &copied)
            return kr == KERN_SUCCESS && copied == 16
        }
    }

    /// Appends `,"frames":[…],"linkRegister":…,"debugImages":[…]` for the
    /// thread interrupted at `context` to `fd`; nothing when its registers
    /// cannot be read. Async-signal-safe.
    static func write(fd: Int32, context: UnsafeMutableRawPointer?) {
        guard let regs = registers(context) else { return }
        withUnsafeTemporaryAllocation(of: UInt.self, capacity: maxFrames) { frames in
            guard let f = frames.baseAddress else { return }
            let n = walk(pc: regs.pc, fp: regs.fp, sp: regs.sp, into: f, capacity: maxFrames)
            guard n > 0 else { return }
            let lr = ThreadSampler.strip(regs.lr)
            write(fd: fd, frames: f, count: n, linkRegister: lr)
        }
    }

    /// The JSON fields for `count` addresses at `frames` (the first is the
    /// pc). Async-signal-safe.
    static func write(fd: Int32, frames f: UnsafeMutablePointer<UInt>, count n: Int, linkRegister lr: UInt) {
        raw(fd, ",\"frames\":[")
        var i = 0
        while i < n {
            raw(fd, i == 0 ? "\"" : ",\"")
            hex(fd, f[i])
            raw(fd, "\"")
            i += 1
        }
        raw(fd, "]")
        if lr != 0 {
            raw(fd, ",\"linkRegister\":\"")
            hex(fd, lr)
            raw(fd, "\"")
        }
        // The images of the frames (and the link register), each once.
        withUnsafeTemporaryAllocation(of: Int.self, capacity: maxFrames + 1) { found in
            guard let seen = found.baseAddress else { return }
            var m = 0
            var j = 0
            while j <= n, m < maxFrames + 1 {
                let address: UInt
                if j < n {
                    address = j == 0 ? f[0] : f[j] &- 1  // return addresses: the call
                } else {
                    address = lr &- 1
                }
                j += 1
                if address == 0 || address == UInt.max { continue }
                let index = BinaryImages.CrashTable.index(containing: address)
                if index < 0 { continue }
                var k = 0
                while k < m, seen[k] != index { k += 1 }
                if k == m {
                    seen[m] = index
                    m += 1
                }
            }
            guard m > 0, let entries = BinaryImages.CrashTable.entries else { return }
            raw(fd, ",\"debugImages\":[")
            var k = 0
            while k < m {
                if k > 0 { raw(fd, ",") }
                let e = entries[seen[k]]
                if let json = e.json { _ = Darwin.write(fd, json, e.length) }
                k += 1
            }
            raw(fd, "]")
        }
    }

    @inline(__always)
    private static func raw(_ fd: Int32, _ s: StaticString) {
        s.withUTF8Buffer { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    /// `0x` and lower-case hex digits, from a stack buffer.
    private static func hex(_ fd: Int32, _ value: UInt) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 18) { digits in
            guard let d = digits.baseAddress else { return }
            var v = value
            var i = 18
            repeat {
                i -= 1
                let nibble = UInt8(v & 0xF)
                d[i] = nibble < 10 ? 48 + nibble : 87 + nibble  // 0-9, a-f
                v >>= 4
            } while v != 0
            i -= 1; d[i] = 120  // x
            i -= 1; d[i] = 48   // 0
            _ = Darwin.write(fd, d + i, 18 - i)
        }
    }
}
#endif
