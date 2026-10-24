package com.unilitix.unilitix_flutter

import android.annotation.TargetApi
import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.Process
import io.unilitix.flutter.nativecrash.KeyValueStore
import io.unilitix.flutter.nativecrash.Logger
import io.unilitix.flutter.nativecrash.MiniJson
import io.unilitix.flutter.nativecrash.NativeCrash
import io.unilitix.flutter.nativecrash.NativeCrashFile
import io.unilitix.flutter.nativecrash.NativeCrashRecord
import io.unilitix.flutter.nativecrash.NativeSignalHandler
import io.unilitix.flutter.nativecrash.ProcessExit
import io.unilitix.flutter.nativecrash.ProcessExits
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream

/**
 * Native (NDK) crash capture on Android, on the Android SDK's implementation
 * (vendored into io.unilitix.flutter.nativecrash and src/main/cpp by
 * scripts/sync-android-native.sh):
 *
 * - API 21-29: `libunilitix-flutter-native.so` installs fatal-signal handlers
 *   at plugin attach. The dying process writes one record to its own file in
 *   `files/unilitix_native_signals/` (one file per process, so a crash before
 *   Dart has read an older record never overwrites it).
 * - API 30+: no native code; the system's `ApplicationExitInfo` history is
 *   scanned for `REASON_CRASH_NATIVE` with the SDK's watermark rule (first
 *   launch with this version: watermark = now, nothing reported; then only
 *   exits newer than the watermark, at most 5).
 *
 * Dart calls `readNativeCrash` at startup until it returns null. The first
 * call of a process collects every record (the JVM crash file, signal
 * records, exit-info crashes), consuming each from disk, and the calls hand
 * them out oldest first, so each is returned exactly once. Consent and
 * session attribution are the Dart side's.
 */
internal object NativeCrashBridge {

    const val SIGNAL_DIRECTORY = "unilitix_native_signals"
    /** Kept separate from the Android SDK's preferences, so each SDK has its own watermark. */
    const val PREFS = "unilitix_flutter_native_crash"
    /** Signal records read per launch (newest kept), as ProcessExits.MAX_REPORTED. */
    const val MAX_SIGNAL_RECORDS = 5
    /** Start of a native crash's tombstone read for its signal (as the Android SDK). */
    private const val MAX_TRACE_BYTES = 256 * 1024

    private var ownSignalFile: File? = null
    private var pending: ArrayDeque<String>? = null

    /** Installs the signal handler (API 21-29 only), once per process. */
    @Synchronized
    fun install(context: Context) {
        if (ownSignalFile != null) return
        val file = File(
            File(context.filesDir, SIGNAL_DIRECTORY),
            "${System.currentTimeMillis()}-${Process.myPid()}.json"
        )
        ownSignalFile = file
        NativeSignalHandler.install(file)
    }

    /** The JVM crash handler reported this exception: the SIGABRT that may follow is not a new crash. */
    fun markExceptionHandled() = NativeSignalHandler.markExceptionHandled()

    /** The next record for Dart, oldest first, or null when there are no more. */
    @Synchronized
    fun next(context: Context): String? {
        val queue = pending ?: ArrayDeque(collect(context)).also { pending = it }
        return queue.removeFirstOrNull()
    }

    private fun collect(context: Context): List<String> {
        val records = ArrayList<String>()
        NativeCrashHandler.consume(context)?.let { records.add(it) }
        val dir = File(context.filesDir, SIGNAL_DIRECTORY)
        for (text in consumeSignalRecords(dir, ownSignalFile)) {
            val crash = NativeCrashRecord.parse(text)
            if (crash != null) records.add(recordFor(crash))
            else Logger.w("Unilitix: native crash record could not be read; dropped")
        }
        if (Build.VERSION.SDK_INT >= 30) {
            // Scanned on every launch so the watermark always moves.
            val store = PrefsStore(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE))
            val scan = ProcessExits.scan(store, readProcessExits(context), System.currentTimeMillis())
            scan.crashes.forEach { records.add(recordFor(it)) }
        }
        return oldestFirst(records)
    }

    /**
     * Reads and deletes the signal records earlier processes left in [dir]
     * ([own] is this process's file, never touched). Newest
     * [MAX_SIGNAL_RECORDS] returned; older ones are deleted unread.
     */
    fun consumeSignalRecords(dir: File, own: File?): List<String> {
        val files = (dir.listFiles() ?: return emptyList())
            .filter { it.isFile && it.name.endsWith(".json") && it.absolutePath != own?.absolutePath }
            .sortedByDescending { it.lastModified() }
        val texts = files.take(MAX_SIGNAL_RECORDS).mapNotNull { NativeCrashFile.consume(it) }
        files.drop(MAX_SIGNAL_RECORDS).forEach { it.delete() }
        return texts
    }

    /** Records sorted by their `timestamp`, oldest first; records without one last. */
    fun oldestFirst(records: List<String>): List<String> =
        records.sortedBy { timestampOf(it) ?: Long.MAX_VALUE }

    private fun timestampOf(record: String): Long? = try {
        (MiniJson(record).readObject()?.get("timestamp") as? Number)?.toLong()?.takeIf { it > 0 }
    } catch (_: IllegalArgumentException) {
        null
    }

    /**
     * The shared crash record for Dart, with `exceptionMessage`
     * (`Fatal signal 11 (SIGSEGV)`) and the contract `fingerprint`
     * (`SIGNAL:11` = `8f1fc15bfa06be00`; an unknown signal is keyed `SIGNAL`
     * and has no `signal`), as UnilitixCore's `CrashFile.consume` adds it on iOS.
     */
    fun recordFor(crash: NativeCrash): String {
        val fields = ArrayList<String>()
        fields += "\"platform\":${quote(crash.platform)}"
        fields += "\"exceptionType\":${quote(crash.exceptionType)}"
        crash.signal?.let { fields += "\"signal\":$it" }
        if (crash.exceptionMessage.isNotEmpty()) fields += "\"exceptionMessage\":${quote(crash.exceptionMessage)}"
        crash.stackTrace?.let { fields += "\"stackTrace\":${quote(it)}" }
        crash.timestampMs?.let { fields += "\"timestamp\":$it" }
        fields += "\"fingerprint\":${quote(crash.fingerprint)}"
        return fields.joinToString(",", "{", "}")
    }

    private fun quote(s: String): String {
        val sb = StringBuilder(s.length + 2).append('"')
        for (c in s) {
            when {
                c == '"' -> sb.append("\\\"")
                c == '\\' -> sb.append("\\\\")
                c == '\n' -> sb.append("\\n")
                c == '\r' -> sb.append("\\r")
                c == '\t' -> sb.append("\\t")
                c < ' ' -> sb.append(String.format("\\u%04x", c.code))
                else -> sb.append(c)
            }
        }
        return sb.append('"').toString()
    }

    @TargetApi(30)
    private fun readProcessExits(context: Context): List<ProcessExit> {
        return try {
            val am = context.getSystemService(ActivityManager::class.java) ?: return emptyList()
            am.getHistoricalProcessExitReasons(context.packageName, 0, ProcessExits.MAX_QUERIED).map { info ->
                ProcessExit(
                    reason = info.reason,
                    timestampMs = info.timestamp,
                    pid = info.pid,
                    description = info.description,
                    readTrace = {
                        // Native crashes carry the tombstone (protobuf) from API 31.
                        if (info.reason == ProcessExits.REASON_CRASH_NATIVE) {
                            info.traceInputStream?.use { readPrefix(it, MAX_TRACE_BYTES) }
                        } else null
                    }
                )
            }
        } catch (e: Exception) {
            Logger.w("Unilitix: could not read process exit reasons: ${e.message}")
            emptyList()
        }
    }

    private fun readPrefix(input: InputStream, max: Int): ByteArray {
        val out = ByteArrayOutputStream()
        val buf = ByteArray(8 * 1024)
        while (out.size() < max) {
            val n = input.read(buf, 0, minOf(buf.size, max - out.size()))
            if (n < 0) break
            out.write(buf, 0, n)
        }
        return out.toByteArray()
    }

    private class PrefsStore(private val prefs: android.content.SharedPreferences) : KeyValueStore {
        override fun getString(key: String): String? = prefs.getString(key, null)
        override fun getBoolean(key: String, default: Boolean): Boolean = prefs.getBoolean(key, default)
        // commit(): the watermark must be on disk before the records are handed to Dart.
        override fun putString(key: String, value: String) { prefs.edit().putString(key, value).commit() }
        override fun putBoolean(key: String, value: Boolean) { prefs.edit().putBoolean(key, value).commit() }
    }
}
