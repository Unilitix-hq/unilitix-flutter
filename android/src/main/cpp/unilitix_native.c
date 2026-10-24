// VENDORED from unilitix-android 1.10.0 (unilitix-sdk/src/main/cpp/unilitix_native.c) by scripts/sync-android-native.sh.
// Do not edit here; change the Android SDK and re-run the script.

/*
 * Unilitix native crash capture for Android 5.0-10 (API 21-29).
 *
 * Fatal signals (SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP: the
 * UnilitixCore / iOS list) write one JSON record to a file passed in at
 * install, in the format every Unilitix SDK shares (UnilitixCore CrashFile):
 *
 *   {"platform":"android","exceptionType":"SIGNAL","signal":11,"timestamp":1760700000000}
 *
 * From 1.10.0 the record also carries the crashed thread's backtrace in the
 * text format of Android tombstones, so the server can symbolicate it with
 * the app's unstripped libraries (matched by GNU build id):
 *
 *   "stackTrace":"#00 pc 000000000001a2b4  /data/app/.../lib/arm64/libshop.so (BuildId: 9f2c...)\n#01 pc ..."
 *
 * The SDK reports the record as a fatal CRASH on the next launch.
 *
 * Order of work in the handler, so that every step can only add to what the
 * previous one saved:
 *  1. the signal-only record is written (open/write/close: as before 1.10.0);
 *  2. the backtrace is captured (see capture_frames) into static buffers;
 *  3. the full record is written to <path>.tmp and rename(2)d over the
 *     signal-only one, so the file is always one complete record.
 * Any failure in 2 or 3 leaves the record from 1.
 *
 * Async-signal safety. Steps 1 and 3 and the module lookup use only
 * async-signal-safe calls (open/read/write/close/rename/clock_gettime/
 * sigaction/sigprocmask/raise) on static or stack memory: no malloc, no
 * stdio, no JNI. The unwinder (_Unwind_Backtrace, from the toolchain's
 * libunwind/libgcc linked into this library) is not async-signal-safe in
 * the strict POSIX sense; it is what the platform and most crash reporters
 * use from signal handlers in practice. Its risks are bounded here:
 *  - memory faults while unwinding or while reading ELF headers are caught:
 *    SIGSEGV/SIGBUS are unblocked for this thread during capture, and a
 *    fault on this thread jumps back (siglongjmp) and abandons the capture;
 *  - at most UNILITIX_MAX_FRAMES frames, one capture per process (the first
 *    fatal signal only);
 *  - the unwinder may take the loader's lock (dl_iterate_phdr) to find
 *    unwind tables: a crash on a thread that holds it is fine (the lock is
 *    recursive), a crash while another thread holds it waits for it.
 * Then it chains to the handler installed before it (on Android normally
 * debuggerd's, which writes the tombstone), or restores the default action
 * and re-raises, so the process dies as it would have.
 *
 * ART handles its own faults (implicit null checks, stack overflow checks)
 * through libsigchain before app handlers run, so only genuine crashes reach
 * this handler.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <jni.h>
#include <signal.h>
#include <setjmp.h>
#include <fcntl.h>
#include <stdio.h> /* rename(2) only */
#include <unistd.h>
#include <stdint.h>
#include <time.h>
#include <elf.h>
#include <ucontext.h>
#include <unwind.h>
#include <sys/syscall.h>


/* Internals below are not static so the host-side unit test can call them;
 * -fvisibility=hidden keeps them out of the library's exports. Kept in this
 * one file (no header) so the Flutter plugin's sync script, which vendors
 * unilitix_native.c alone, keeps working. */
#define UNILITIX_MAX_FRAMES 64
#define UNILITIX_MODULE_PATH_MAX 256
#define UNILITIX_BUILD_ID_MAX 72 /* 32-byte id as hex + NUL, with room */

/* One line of /proc/self/maps. */
typedef struct {
    uintptr_t start;
    uintptr_t end;
    uintptr_t offset;
    int readable;
    int executable;
    char path[UNILITIX_MODULE_PATH_MAX];
} unilitix_mapping;

/* One frame of the crashed thread. pc is absolute; once resolved, rel_pc is
 * the address within the ELF file (as tombstones print it), file_offset the
 * ELF's offset in the mapped file (non-zero for a library mapped from the
 * APK) and build_id its GNU build id in hex ("" when unknown). */
typedef struct {
    uintptr_t pc;
    uintptr_t rel_pc;
    uintptr_t file_offset;
    int resolved;
    char path[UNILITIX_MODULE_PATH_MAX];
    char build_id[UNILITIX_BUILD_ID_MAX];
} unilitix_frame;

/* Parses "start-end perms offset dev inode path"; 1 on success. */
int unilitix_parse_maps_line(const char *line, int len, unilitix_mapping *out);

/* 1 when base points at an ELF header of this process's class. */
int unilitix_is_elf(const void *base);

/* Reads the ELF image whose header is at base (readable up to limit): its
 * load bias (address of virtual address 0) and GNU build id. 1 on success
 * (build_id may still be ""). */
int unilitix_elf_info(uintptr_t base, uintptr_t limit, uintptr_t *load_bias, char *build_id, int build_id_cap);

/* Return address -> an address inside the call instruction. */
uintptr_t unilitix_call_site(uintptr_t return_address);

/* Frame 0 is pc; then the unwound frames after the one equal to pc, else
 * the link register. Returns the number of frames. */
int unilitix_select_frames(uintptr_t pc, uintptr_t lr, const uintptr_t *raw, int raw_count,
                           unilitix_frame *frames, int max);

/* Resolves frames against /proc/self/maps read from maps_fd. */
void unilitix_resolve_frames(int maps_fd, unilitix_frame *frames, int count);

/* Writes the frames as the inside of a JSON string (lines joined by \n
 * escapes), at most cap bytes; returns the length. */
int unilitix_format_frames(const unilitix_frame *frames, int count, char *buf, int cap);

#define UNILITIX_SIGNAL_COUNT 6
#define UNILITIX_PATH_MAX 1024
#define UNILITIX_ALT_STACK_SIZE (32 * 1024)
/* Raw unwinder frames: the handler's own frames and the signal trampoline
 * come first, then up to UNILITIX_MAX_FRAMES of the crashed thread. */
#define UNILITIX_MAX_RAW (UNILITIX_MAX_FRAMES + 16)
#define UNILITIX_RECORD_MAX (40 * 1024)

static const int k_signals[UNILITIX_SIGNAL_COUNT] = {
    SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP
};

/* Written once by install, read-only afterwards (the handler only reads). */
static struct sigaction g_previous[UNILITIX_SIGNAL_COUNT];
static int g_has_previous[UNILITIX_SIGNAL_COUNT];
static char g_path[UNILITIX_PATH_MAX];
static char g_tmp_path[UNILITIX_PATH_MAX + 8];
static int g_installed = 0;

/* Set by the JVM crash handler (CrashHandler) and fatal recordException():
 * the exception was reported already, so a signal that follows it (SIGABRT
 * from abort()) must not be reported again. */
static volatile sig_atomic_t g_exception_handled = 0;
/* Only the first fatal signal writes a record. */
static volatile int g_record_written = 0;

/* Fault guard for the capture (see the header comment). */
static sigjmp_buf g_guard_jmp;
static volatile sig_atomic_t g_guard_active = 0;
static volatile long g_guard_tid = 0;

/* Capture state: static, used by the one thread that won g_record_written. */
static uintptr_t g_raw[UNILITIX_MAX_RAW];
static unilitix_frame g_frames[UNILITIX_MAX_FRAMES];
static char g_maps_buf[4096];
static char g_record[UNILITIX_RECORD_MAX];

/* Used when the thread has no alternate stack, so a stack-overflow SIGSEGV
 * can still run the handler. bss: costs nothing on disk. */
static char g_alt_stack[UNILITIX_ALT_STACK_SIZE] __attribute__((aligned(16)));

static int signal_index(int sig) {
    for (int i = 0; i < UNILITIX_SIGNAL_COUNT; i++) {
        if (k_signals[i] == sig) return i;
    }
    return -1;
}

static long current_tid(void) {
    return (long) syscall(SYS_gettid);
}

/* ── Text helpers (no libc) ─────────────────────────────────────────── */

/* Appends src (NUL-terminated) to buf at *pos, never past cap. */
static void append_str(char *buf, int *pos, int cap, const char *src) {
    while (*src && *pos < cap) buf[(*pos)++] = *src++;
}

/* Appends a non-negative decimal (negative values are written as 0). */
static void append_dec(char *buf, int *pos, int cap, long long value) {
    char digits[24];
    int n = 0;
    unsigned long long v = value < 0 ? 0ULL : (unsigned long long) value;
    do {
        digits[n++] = (char) ('0' + (int) (v % 10ULL));
        v /= 10ULL;
    } while (v > 0 && n < (int) sizeof(digits));
    while (n > 0 && *pos < cap) buf[(*pos)++] = digits[--n];
}

/* Appends value in lowercase hex, zero-padded to at least width digits. */
static void append_hex(char *buf, int *pos, int cap, uint64_t value, int width) {
    char digits[16];
    int n = 0;
    do {
        digits[n++] = "0123456789abcdef"[value & 0xf];
        value >>= 4;
    } while (value != 0 && n < 16);
    while (n < width && n < 16) digits[n++] = '0';
    while (n > 0 && *pos < cap) buf[(*pos)++] = digits[--n];
}

/* Appends src as the inside of a JSON string. */
static void append_json(char *buf, int *pos, int cap, const char *src) {
    for (; *src && *pos < cap; src++) {
        unsigned char c = (unsigned char) *src;
        if (c == '"' || c == '\\') {
            if (*pos + 2 > cap) return;
            buf[(*pos)++] = '\\';
            buf[(*pos)++] = (char) c;
        } else if (c < 0x20 || c == 0x7f) {
            buf[(*pos)++] = '?';
        } else {
            buf[(*pos)++] = (char) c;
        }
    }
}

/* ── /proc/self/maps ────────────────────────────────────────────────── */

static int parse_hex(const char *s, int len, int *i, uint64_t *out) {
    uint64_t v = 0;
    int start = *i;
    while (*i < len) {
        char c = s[*i];
        int d;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else break;
        if (*i - start >= 16) return 0;
        v = (v << 4) | (uint64_t) d;
        (*i)++;
    }
    if (*i == start) return 0;
    *out = v;
    return 1;
}

int unilitix_parse_maps_line(const char *line, int len, unilitix_mapping *out) {
    int i = 0;
    uint64_t start, end, offset;
    if (!parse_hex(line, len, &i, &start) || i >= len || line[i] != '-') return 0;
    i++;
    if (!parse_hex(line, len, &i, &end) || i >= len || line[i] != ' ' || end <= start) return 0;
    i++;
    if (i + 4 >= len) return 0;
    out->readable = line[i] == 'r';
    out->executable = line[i + 2] == 'x';
    i += 4;
    if (i >= len || line[i] != ' ') return 0;
    i++;
    if (!parse_hex(line, len, &i, &offset)) return 0;
    /* dev and inode */
    for (int field = 0; field < 2; field++) {
        while (i < len && line[i] == ' ') i++;
        while (i < len && line[i] != ' ') i++;
    }
    while (i < len && line[i] == ' ') i++;
    int n = 0;
    while (i < len && line[i] != '\n' && n < UNILITIX_MODULE_PATH_MAX - 1) out->path[n++] = line[i++];
    out->path[n] = '\0';
    out->start = (uintptr_t) start;
    out->end = (uintptr_t) end;
    out->offset = (uintptr_t) offset;
    return 1;
}

/* ── ELF headers in memory ──────────────────────────────────────────── */

#if UINTPTR_MAX == 0xffffffffffffffffULL
typedef Elf64_Ehdr unilitix_ehdr;
typedef Elf64_Phdr unilitix_phdr;
#define UNILITIX_ELFCLASS ELFCLASS64
#define UNILITIX_PC_WIDTH 16
#else
typedef Elf32_Ehdr unilitix_ehdr;
typedef Elf32_Phdr unilitix_phdr;
#define UNILITIX_ELFCLASS ELFCLASS32
#define UNILITIX_PC_WIDTH 8
#endif

/* An ELF note header: three 32-bit words in both classes. */
typedef struct {
    uint32_t n_namesz;
    uint32_t n_descsz;
    uint32_t n_type;
} unilitix_nhdr;

#ifndef NT_GNU_BUILD_ID
#define NT_GNU_BUILD_ID 3
#endif

int unilitix_is_elf(const void *base) {
    const unsigned char *p = (const unsigned char *) base;
    return p[0] == 0x7f && p[1] == 'E' && p[2] == 'L' && p[3] == 'F' && p[4] == UNILITIX_ELFCLASS;
}

/* Reads a GNU build-id note from [notes, notes + size) into hex. */
static int read_build_id_note(const unsigned char *notes, uintptr_t size, char *hex, int hex_cap) {
    uintptr_t off = 0;
    while (off + sizeof(unilitix_nhdr) <= size) {
        const unilitix_nhdr *nh = (const unilitix_nhdr *) (notes + off);
        uintptr_t name_size = (nh->n_namesz + 3u) & ~3u;
        uintptr_t desc_size = (nh->n_descsz + 3u) & ~3u;
        uintptr_t name_off = off + sizeof(unilitix_nhdr);
        uintptr_t desc_off = name_off + name_size;
        if (nh->n_namesz > 64 || nh->n_descsz > 256 || desc_off + desc_size > size) return 0;
        const unsigned char *name = notes + name_off;
        if (nh->n_type == NT_GNU_BUILD_ID && nh->n_namesz == 4 &&
            name[0] == 'G' && name[1] == 'N' && name[2] == 'U' && name[3] == '\0') {
            const unsigned char *desc = notes + desc_off;
            int n = 0;
            for (uintptr_t k = 0; k < nh->n_descsz && n + 2 < hex_cap; k++) {
                hex[n++] = "0123456789abcdef"[desc[k] >> 4];
                hex[n++] = "0123456789abcdef"[desc[k] & 0xf];
            }
            hex[n] = '\0';
            return n > 0;
        }
        off = desc_off + desc_size;
    }
    return 0;
}

int unilitix_elf_info(uintptr_t base, uintptr_t limit, uintptr_t *load_bias, char *build_id, int build_id_cap) {
    if (limit < base + sizeof(unilitix_ehdr)) return 0;
    const unilitix_ehdr *eh = (const unilitix_ehdr *) base;
    if (!unilitix_is_elf(eh)) return 0;
    if (eh->e_phentsize != sizeof(unilitix_phdr) || eh->e_phnum == 0 || eh->e_phnum > 64) return 0;
    uintptr_t ph_start = base + (uintptr_t) eh->e_phoff;
    if (ph_start < base || ph_start + (uintptr_t) eh->e_phnum * sizeof(unilitix_phdr) > limit) return 0;
    const unilitix_phdr *ph = (const unilitix_phdr *) ph_start;

    /* The mapping at base holds file offset 0 of the ELF: the PT_LOAD that
     * covers offset 0 says which virtual address that is. */
    int found = 0;
    uintptr_t bias = 0;
    for (int i = 0; i < eh->e_phnum; i++) {
        if (ph[i].p_type == PT_LOAD && ph[i].p_offset == 0) {
            bias = base - (uintptr_t) ph[i].p_vaddr;
            found = 1;
            break;
        }
    }
    if (!found) return 0;
    *load_bias = bias;
    build_id[0] = '\0';
    for (int i = 0; i < eh->e_phnum; i++) {
        if (ph[i].p_type != PT_NOTE) continue;
        uintptr_t note = bias + (uintptr_t) ph[i].p_vaddr;
        uintptr_t size = (uintptr_t) ph[i].p_memsz;
        if (size == 0 || size > 4096 || note < bias) continue;
        if (read_build_id_note((const unsigned char *) note, size, build_id, build_id_cap)) break;
    }
    return 1;
}

/* ── Frames → modules ───────────────────────────────────────────────── */

/* Consecutive mappings of one file, newest last (enough for a library's
 * r--p / r-xp / r--p / rw-p segments). */
#define UNILITIX_RUN_MAX 8
typedef struct {
    char path[UNILITIX_MODULE_PATH_MAX];
    uintptr_t start[UNILITIX_RUN_MAX];
    uintptr_t end[UNILITIX_RUN_MAX];
    uintptr_t offset[UNILITIX_RUN_MAX];
    int readable[UNILITIX_RUN_MAX];
    int n;
} map_run;

static map_run g_run;
static unilitix_mapping g_line_map;

static int same_path(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

static void copy_path(char *dst, const char *src) {
    int n = 0;
    while (src[n] && n < UNILITIX_MODULE_PATH_MAX - 1) { dst[n] = src[n]; n++; }
    dst[n] = '\0';
}

/* Reads the ELF header of a run entry; guarded so a bad address abandons
 * only this lookup. */
static int guarded_elf_info(uintptr_t base, uintptr_t limit, uintptr_t *bias, char *build_id, int cap) {
    volatile int ok = 0;
    g_guard_active = 1;
    if (sigsetjmp(g_guard_jmp, 1) == 0) {
        ok = unilitix_elf_info(base, limit, bias, build_id, cap);
    }
    g_guard_active = 0;
    return ok;
}

static void resolve_in_run(unilitix_frame *f, const map_run *run) {
    int k = run->n - 1; /* the mapping that contains pc */
    copy_path(f->path, run->path);
    f->resolved = 1;
    /* The ELF starts at the nearest earlier readable mapping of the same
     * file that begins with an ELF header (offset 0 for an extracted .so,
     * the library's offset inside base.apk for one mapped from the APK). */
    for (int j = k; j >= 0; j--) {
        if (!run->readable[j]) continue;
        uintptr_t bias;
        char id[UNILITIX_BUILD_ID_MAX];
        if (guarded_elf_info(run->start[j], run->end[j], &bias, id, (int) sizeof(id)) && f->pc >= bias) {
            f->rel_pc = f->pc - bias;
            f->file_offset = run->offset[j];
            for (int c = 0; c < UNILITIX_BUILD_ID_MAX; c++) {
                f->build_id[c] = id[c];
                if (id[c] == '\0') break;
            }
            return;
        }
    }
    /* No ELF header found: the offset within the file is the best we have. */
    f->rel_pc = f->pc - run->start[k] + run->offset[k];
    f->build_id[0] = '\0';
}

static void on_mapping(const unilitix_mapping *m, unilitix_frame *frames, int count) {
    if (m->path[0] != '\0' && g_run.n > 0 && same_path(g_run.path, m->path)) {
        if (g_run.n == UNILITIX_RUN_MAX) {
            for (int j = 1; j < UNILITIX_RUN_MAX; j++) {
                g_run.start[j - 1] = g_run.start[j];
                g_run.end[j - 1] = g_run.end[j];
                g_run.offset[j - 1] = g_run.offset[j];
                g_run.readable[j - 1] = g_run.readable[j];
            }
            g_run.n--;
        }
    } else {
        copy_path(g_run.path, m->path);
        g_run.n = 0;
    }
    g_run.start[g_run.n] = m->start;
    g_run.end[g_run.n] = m->end;
    g_run.offset[g_run.n] = m->offset;
    g_run.readable[g_run.n] = m->readable;
    g_run.n++;

    for (int i = 0; i < count; i++) {
        unilitix_frame *f = &frames[i];
        if (f->resolved || f->pc < m->start || f->pc >= m->end) continue;
        if (m->path[0] == '\0') {
            f->resolved = 1;
            f->rel_pc = f->pc;
            f->path[0] = '\0';
            f->build_id[0] = '\0';
        } else if (m->path[0] == '[') {
            /* [anon:...], [vdso]...: no file to look up. */
            f->resolved = 1;
            f->rel_pc = f->pc - m->start;
            copy_path(f->path, m->path);
            f->build_id[0] = '\0';
        } else {
            resolve_in_run(f, &g_run);
        }
    }
}

void unilitix_resolve_frames(int maps_fd, unilitix_frame *frames, int count) {
    char line[UNILITIX_MODULE_PATH_MAX + 128];
    int line_len = 0;
    int skipping = 0; /* the current line is too long: ignore it */
    g_run.n = 0;
    g_run.path[0] = '\0';
    for (;;) {
        ssize_t n = read(maps_fd, g_maps_buf, sizeof(g_maps_buf));
        if (n <= 0) break;
        for (ssize_t i = 0; i < n; i++) {
            char c = g_maps_buf[i];
            if (c == '\n') {
                if (!skipping && unilitix_parse_maps_line(line, line_len, &g_line_map)) {
                    on_mapping(&g_line_map, frames, count);
                }
                line_len = 0;
                skipping = 0;
            } else if (!skipping) {
                if (line_len < (int) sizeof(line)) line[line_len++] = c;
                else skipping = 1;
            }
        }
    }
    if (line_len > 0 && !skipping && unilitix_parse_maps_line(line, line_len, &g_line_map)) {
        on_mapping(&g_line_map, frames, count);
    }
}

/* ── Unwinding ──────────────────────────────────────────────────────── */

typedef struct {
    uintptr_t *pcs;
    int n;
    int cap;
} unwind_state;

static _Unwind_Reason_Code unwind_one(struct _Unwind_Context *ctx, void *arg) {
    unwind_state *s = (unwind_state *) arg;
    uintptr_t ip = (uintptr_t) _Unwind_GetIP(ctx);
    if (ip == 0 || s->n >= s->cap) return _URC_END_OF_STACK;
    s->pcs[s->n++] = ip;
    return _URC_NO_REASON;
}

/* A return address moved back into the call instruction, as unwindstack
 * does for tombstones, so the line looked up is the call's. */
uintptr_t unilitix_call_site(uintptr_t return_address) {
#if defined(__aarch64__)
    return return_address >= 4 ? return_address - 4 : return_address;
#elif defined(__arm__)
    return return_address >= 2 ? return_address - 2 : return_address;
#else
    return return_address >= 1 ? return_address - 1 : return_address;
#endif
}

static int context_pcs(void *ucontext, uintptr_t *pc, uintptr_t *lr) {
    ucontext_t *uc = (ucontext_t *) ucontext;
    *lr = 0;
    if (uc == NULL) return 0;
#if defined(__aarch64__)
    *pc = (uintptr_t) uc->uc_mcontext.pc;
    *lr = (uintptr_t) uc->uc_mcontext.regs[30];
#elif defined(__arm__)
    *pc = (uintptr_t) uc->uc_mcontext.arm_pc;
    *lr = (uintptr_t) uc->uc_mcontext.arm_lr & ~(uintptr_t) 1;
#elif defined(__x86_64__)
    *pc = (uintptr_t) uc->uc_mcontext.gregs[REG_RIP];
#elif defined(__i386__)
    *pc = (uintptr_t) uc->uc_mcontext.gregs[REG_EIP];
#else
    return 0;
#endif
    return *pc != 0;
}

int unilitix_select_frames(uintptr_t pc, uintptr_t lr, const uintptr_t *raw, int raw_count,
                           unilitix_frame *frames, int max) {
    int n = 0;
    if (max <= 0 || pc == 0) return 0;
    frames[n].pc = pc;
    frames[n].resolved = 0;
    n++;
    /* The unwinder walks the handler's own frames and the signal
     * trampoline first; the crashed frame is the one whose ip equals the
     * interrupted pc. Every frame after it is a return address. */
    int at = -1;
    for (int i = 0; i < raw_count; i++) {
        if (raw[i] == pc) { at = i; break; }
    }
    if (at >= 0) {
        for (int i = at + 1; i < raw_count && n < max; i++) {
            frames[n].pc = unilitix_call_site(raw[i]);
            frames[n].resolved = 0;
            n++;
        }
    } else if (lr != 0 && lr != pc && n < max) {
        /* Unwinding did not reach the crashed frame (no unwind info there):
         * the link register is the caller when the crash was in a leaf. */
        frames[n].pc = unilitix_call_site(lr);
        frames[n].resolved = 0;
        n++;
    }
    return n;
}

/* Unwinds and resolves; returns the number of frames (0 on any failure). */
static int capture_frames(void *ucontext) {
    uintptr_t pc = 0, lr = 0;
    if (!context_pcs(ucontext, &pc, &lr)) return 0;

    volatile int raw_count = 0;
    unwind_state state;
    state.pcs = g_raw;
    state.n = 0;
    state.cap = UNILITIX_MAX_RAW;
    g_guard_active = 1;
    if (sigsetjmp(g_guard_jmp, 1) == 0) {
        _Unwind_Backtrace(unwind_one, &state);
        raw_count = state.n;
    }
    g_guard_active = 0;

    int count = unilitix_select_frames(pc, lr, g_raw, raw_count, g_frames, UNILITIX_MAX_FRAMES);
    if (count == 0) return 0;
    int fd = open("/proc/self/maps", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    unilitix_resolve_frames(fd, g_frames, count);
    close(fd);
    return count;
}

/* ── The record ─────────────────────────────────────────────────────── */

int unilitix_format_frames(const unilitix_frame *frames, int count, char *buf, int cap) {
    int pos = 0;
    for (int i = 0; i < count; i++) {
        const unilitix_frame *f = &frames[i];
        if (i > 0) append_str(buf, &pos, cap, "\\n");
        append_str(buf, &pos, cap, "#");
        if (i < 10) append_str(buf, &pos, cap, "0");
        append_dec(buf, &pos, cap, i);
        append_str(buf, &pos, cap, " pc ");
        append_hex(buf, &pos, cap, f->resolved ? f->rel_pc : f->pc, UNILITIX_PC_WIDTH);
        append_str(buf, &pos, cap, "  ");
        if (!f->resolved || f->path[0] == '\0') {
            append_str(buf, &pos, cap, "<unknown>");
            continue;
        }
        append_json(buf, &pos, cap, f->path);
        if (f->file_offset != 0) {
            append_str(buf, &pos, cap, " (offset 0x");
            append_hex(buf, &pos, cap, f->file_offset, 1);
            append_str(buf, &pos, cap, ")");
        }
        if (f->build_id[0] != '\0') {
            append_str(buf, &pos, cap, " (BuildId: ");
            append_str(buf, &pos, cap, f->build_id);
            append_str(buf, &pos, cap, ")");
        }
    }
    return pos;
}

static int format_record(char *buf, int cap, int sig, long long ms, const unilitix_frame *frames, int count) {
    int pos = 0;
    append_str(buf, &pos, cap, "{\"platform\":\"android\",\"exceptionType\":\"SIGNAL\",\"signal\":");
    append_dec(buf, &pos, cap, sig);
    append_str(buf, &pos, cap, ",\"timestamp\":");
    append_dec(buf, &pos, cap, ms);
    if (count > 0) {
        append_str(buf, &pos, cap, ",\"stackTrace\":\"");
        /* Leave room for the closing quote and brace. */
        pos += unilitix_format_frames(frames, count, buf + pos, cap - pos - 2);
        append_str(buf, &pos, cap, "\"");
    }
    append_str(buf, &pos, cap, "}");
    return pos;
}

static int write_file(const char *path, const char *buf, int len) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) return 0;
    int off = 0;
    while (off < len) {
        ssize_t w = write(fd, buf + off, (size_t) (len - off));
        if (w <= 0) break;
        off += (int) w;
    }
    close(fd);
    return off == len;
}

static void write_records(int sig, void *ucontext) {
    char small[160];
    long long ms = 0;
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) == 0) {
        ms = (long long) ts.tv_sec * 1000LL + (long long) (ts.tv_nsec / 1000000L);
    }
    /* 1. The signal-only record, as before 1.10.0. */
    int len = format_record(small, (int) sizeof(small), sig, ms, NULL, 0);
    if (!write_file(g_path, small, len)) return;

    /* 2. The backtrace, with SIGSEGV/SIGBUS deliverable to this thread so a
     * fault while capturing reaches the guard instead of killing the
     * process without a tombstone. sigsetjmp(…, 1) in the guards restores
     * this mask when they jump. */
    sigset_t faults, saved;
    sigemptyset(&faults);
    sigaddset(&faults, SIGSEGV);
    sigaddset(&faults, SIGBUS);
    g_guard_tid = current_tid();
    sigprocmask(SIG_UNBLOCK, &faults, &saved);
    int count = capture_frames(ucontext);
    sigprocmask(SIG_SETMASK, &saved, NULL);
    g_guard_tid = 0;
    if (count == 0) return;

    /* 3. The full record, replacing the first one atomically. */
    len = format_record(g_record, (int) sizeof(g_record), sig, ms, g_frames, count);
    if (write_file(g_tmp_path, g_record, len)) rename(g_tmp_path, g_path);
}

/* ── Handler ────────────────────────────────────────────────────────── */

static int is_ignored(const struct sigaction *action) {
    return !(action->sa_flags & SA_SIGINFO) && action->sa_handler == SIG_IGN;
}

/* Runs the handler installed before ours, or the default action. */
static void chain(int idx, int sig, siginfo_t *info, void *ucontext) {
    if (idx >= 0 && g_has_previous[idx]) {
        struct sigaction previous = g_previous[idx];
        /* Reinstall theirs first so a crash inside it cannot loop back here. */
        sigaction(sig, &previous, NULL);
        if (previous.sa_flags & SA_SIGINFO) {
            if (previous.sa_sigaction != NULL) {
                previous.sa_sigaction(sig, info, ucontext);
                return;
            }
        } else if (previous.sa_handler == SIG_IGN) {
            /* The app ignores this signal: keep ignoring it. (A hardware
             * fault re-executes and the kernel forces the default action.) */
            return;
        } else if (previous.sa_handler != SIG_DFL) {
            previous.sa_handler(sig);
            return;
        }
    }
    /* Default action. The signal is blocked while this handler runs, so
     * raise() leaves it pending: it is delivered, with the default action,
     * as soon as we return (a hardware fault would also simply recur). */
    signal(sig, SIG_DFL);
    raise(sig);
}

static void unilitix_handle_signal(int sig, siginfo_t *info, void *ucontext) {
    /* A fault inside our own capture: abandon it (see write_records). */
    if (g_guard_active && (sig == SIGSEGV || sig == SIGBUS) && g_guard_tid == current_tid()) {
        siglongjmp(g_guard_jmp, 1);
    }
    int idx = signal_index(sig);
    int ignored = idx >= 0 && g_has_previous[idx] && is_ignored(&g_previous[idx]);
    if (!ignored && !g_exception_handled &&
        __sync_bool_compare_and_swap(&g_record_written, 0, 1)) {
        write_records(sig, ucontext);
    }
    chain(idx, sig, info, ucontext);
}

static int install_handlers(void) {
    /* Bionic gives every thread an alternate signal stack; only add ours to
     * a thread that has none. */
    stack_t current;
    if (sigaltstack(NULL, &current) == 0 && (current.ss_flags & SS_DISABLE)) {
        stack_t ss;
        ss.ss_sp = g_alt_stack;
        ss.ss_size = sizeof(g_alt_stack);
        ss.ss_flags = 0;
        sigaltstack(&ss, NULL);
    }

    int installed = 0;
    for (int i = 0; i < UNILITIX_SIGNAL_COUNT; i++) {
        struct sigaction action;
        struct sigaction previous;
        /* Zeroed byte by byte: no libc beyond the signal calls. */
        char *a = (char *) &action;
        for (unsigned int b = 0; b < sizeof(action); b++) a[b] = 0;
        action.sa_sigaction = unilitix_handle_signal;
        action.sa_flags = SA_SIGINFO | SA_ONSTACK;
        sigemptyset(&action.sa_mask);
        if (sigaction(k_signals[i], &action, &previous) == 0) {
            g_previous[i] = previous;
            g_has_previous[i] = 1;
            installed++;
        }
    }
    return installed > 0;
}

JNIEXPORT jboolean JNICALL
Java_io_unilitix_flutter_nativecrash_NativeSignalHandler_nativeInstall(JNIEnv *env, jclass clazz, jstring path) {
    (void) clazz;
    if (g_installed) return JNI_TRUE;
    if (path == NULL) return JNI_FALSE;
    const char *chars = (*env)->GetStringUTFChars(env, path, NULL);
    if (chars == NULL) return JNI_FALSE;
    int n = 0;
    while (chars[n] != '\0' && n < UNILITIX_PATH_MAX - 1) {
        g_path[n] = chars[n];
        g_tmp_path[n] = chars[n];
        n++;
    }
    int too_long = chars[n] != '\0';
    g_path[n] = '\0';
    (*env)->ReleaseStringUTFChars(env, path, chars);
    if (too_long || n == 0) return JNI_FALSE;
    /* NativeCrashFile.pending(): <path>.tmp */
    g_tmp_path[n] = '.';
    g_tmp_path[n + 1] = 't';
    g_tmp_path[n + 2] = 'm';
    g_tmp_path[n + 3] = 'p';
    g_tmp_path[n + 4] = '\0';

    g_exception_handled = 0;
    g_record_written = 0;
    if (!install_handlers()) return JNI_FALSE;
    g_installed = 1;
    return JNI_TRUE;
}

JNIEXPORT void JNICALL
Java_io_unilitix_flutter_nativecrash_NativeSignalHandler_nativeMarkExceptionHandled(JNIEnv *env, jclass clazz) {
    (void) env;
    (void) clazz;
    g_exception_handled = 1;
}
