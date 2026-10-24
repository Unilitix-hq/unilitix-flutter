// VENDORED from unilitix-android 1.7.0 (unilitix-sdk/src/main/cpp/unilitix_native.c) by scripts/sync-android-native.sh.
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
 * The SDK reports the record as a fatal CRASH on the next launch.
 *
 * The handler is async-signal-safe: open/write/close/clock_gettime/sigaction/
 * raise on static or stack memory only (no malloc, no stdio, no JNI). Then it
 * chains to the handler installed before it (on Android normally debuggerd's,
 * which writes the tombstone), or restores the default action and re-raises,
 * so the process dies as it would have.
 *
 * ART handles its own faults (implicit null checks, stack overflow checks)
 * through libsigchain before app handlers run, so only genuine crashes reach
 * this handler.
 */
#include <jni.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>

#define UNILITIX_SIGNAL_COUNT 6
#define UNILITIX_PATH_MAX 1024
#define UNILITIX_ALT_STACK_SIZE (32 * 1024)

static const int k_signals[UNILITIX_SIGNAL_COUNT] = {
    SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP
};

/* Written once by install, read-only afterwards (the handler only reads). */
static struct sigaction g_previous[UNILITIX_SIGNAL_COUNT];
static int g_has_previous[UNILITIX_SIGNAL_COUNT];
static char g_path[UNILITIX_PATH_MAX];
static int g_installed = 0;

/* Set by the JVM crash handler (CrashHandler) and fatal recordException():
 * the exception was reported already, so a signal that follows it (SIGABRT
 * from abort()) must not be reported again. */
static volatile sig_atomic_t g_exception_handled = 0;
/* Only the first fatal signal writes a record. */
static volatile int g_record_written = 0;

/* Used when the thread has no alternate stack, so a stack-overflow SIGSEGV
 * can still run the handler. bss: costs nothing on disk. */
static char g_alt_stack[UNILITIX_ALT_STACK_SIZE] __attribute__((aligned(16)));

static int signal_index(int sig) {
    for (int i = 0; i < UNILITIX_SIGNAL_COUNT; i++) {
        if (k_signals[i] == sig) return i;
    }
    return -1;
}

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

static void write_record(int sig) {
    char buf[160];
    int pos = 0;
    const int cap = (int) sizeof(buf);
    long long ms = 0;
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) == 0) {
        ms = (long long) ts.tv_sec * 1000LL + (long long) (ts.tv_nsec / 1000000L);
    }
    append_str(buf, &pos, cap, "{\"platform\":\"android\",\"exceptionType\":\"SIGNAL\",\"signal\":");
    append_dec(buf, &pos, cap, sig);
    append_str(buf, &pos, cap, ",\"timestamp\":");
    append_dec(buf, &pos, cap, ms);
    append_str(buf, &pos, cap, "}");

    int fd = open(g_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) return;
    int off = 0;
    while (off < pos) {
        ssize_t w = write(fd, buf + off, (size_t) (pos - off));
        if (w <= 0) break;
        off += (int) w;
    }
    close(fd);
}

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
    int idx = signal_index(sig);
    int ignored = idx >= 0 && g_has_previous[idx] && is_ignored(&g_previous[idx]);
    if (!ignored && !g_exception_handled &&
        __sync_bool_compare_and_swap(&g_record_written, 0, 1)) {
        write_record(sig);
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
        n++;
    }
    int too_long = chars[n] != '\0';
    g_path[n] = '\0';
    (*env)->ReleaseStringUTFChars(env, path, chars);
    if (too_long || n == 0) return JNI_FALSE;

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
