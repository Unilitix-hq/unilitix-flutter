// VENDORED from unilitix-android 1.7.0 (unilitix-sdk/src/main/java/io/unilitix/sdk/capture/NativeCrash.kt) by scripts/sync-android-native.sh.
// Do not edit here; change the Android SDK and re-run the script.

package io.unilitix.flutter.nativecrash

import java.io.File

/**
 * A native crash of an earlier process, from either source:
 * - the record [NativeSignalHandler] wrote to [NativeCrashFile] (API 21-29),
 * - an `ApplicationExitInfo` with `REASON_CRASH_NATIVE` (API 30+, [ProcessExits]).
 *
 * Reported on the next launch as a fatal CRASH with the same shape as
 * UnilitixCore (iOS) 0.5.0 and the Flutter SDK report for a native record.
 */
internal data class NativeCrash(
    /** `SIGNAL` for a signal; a record from another SDK may name an exception. */
    val exceptionType: String,
    /** The signal number, or null when unknown. */
    val signal: Int?,
    val exceptionMessage: String,
    val stackTrace: String?,
    /** When the process died (ms since 1970), or null when unknown. */
    val timestampMs: Long?,
    val platform: String,
    val fingerprint: String
)

/** The crash-record format every Unilitix SDK shares (UnilitixCore `CrashFile`). */
internal object NativeCrashRecord {

    const val SIGNAL_TYPE = "SIGNAL"
    const val PLATFORM = "android"
    private const val MAX_STACK = 16 * 1024

    /** Android (Linux) numbers of the signals the handler catches, as UnilitixCore names them. */
    private val names = mapOf(
        6 to "SIGABRT",
        7 to "SIGBUS",
        8 to "SIGFPE",
        4 to "SIGILL",
        11 to "SIGSEGV",
        5 to "SIGTRAP"
    )

    /** `SIGSEGV` for 11 and so on, for the signals the handler catches; null otherwise. */
    fun signalName(signal: Int): String? = names[signal]

    /**
     * The crash's fingerprint: `SIGNAL:<n>` for a signal (each signal its own
     * group: `SIGNAL:11` is `8f1fc15bfa06be00` on every SDK), the bare type
     * when the signal is unknown (as UnilitixCore does for a record without
     * one), else the exception type and stack.
     */
    fun fingerprint(exceptionType: String, signal: Int?, stackTrace: String?): String =
        Fingerprint.of(if (signal != null) "$exceptionType:$signal" else exceptionType, stackTrace)

    /** The message UnilitixCore gives a signal: `Fatal signal 11 (SIGSEGV)`. */
    fun signalMessage(signal: Int?): String {
        if (signal == null) return ""
        return signalName(signal)?.let { "Fatal signal $signal ($it)" } ?: "Fatal signal $signal"
    }

    /** A signal crash (from the exit-info path): [signal] null when it could not be read. */
    fun fromSignal(signal: Int?, timestampMs: Long?): NativeCrash = NativeCrash(
        exceptionType = SIGNAL_TYPE,
        signal = signal,
        exceptionMessage = signalMessage(signal),
        stackTrace = null,
        timestampMs = timestampMs?.takeIf { it > 0 },
        platform = PLATFORM,
        fingerprint = fingerprint(SIGNAL_TYPE, signal, null)
    )

    /**
     * Reads a record such as
     * `{"platform":"android","exceptionType":"SIGNAL","signal":11,"timestamp":1760700000000}`.
     * Null when it is not a JSON object with an `exceptionType`.
     */
    fun parse(text: String): NativeCrash? {
        val record = try {
            MiniJson(text).readObject()
        } catch (e: IllegalArgumentException) {
            return null
        } ?: return null
        val type = (record["exceptionType"] as? String)?.takeIf { it.isNotEmpty() } ?: return null
        val signal = (record["signal"] as? Number)?.toInt()
        val message = (record["exceptionMessage"] as? String)?.takeIf { it.isNotEmpty() }
            ?: signalMessage(signal)
        val stack = (record["stackTrace"] as? String)?.takeIf { it.isNotEmpty() }?.take(MAX_STACK)
        val timestamp = (record["timestamp"] as? Number)?.toLong()?.takeIf { it > 0 }
        val fingerprint = (record["fingerprint"] as? String)?.takeIf { it.isNotEmpty() }
            ?: fingerprint(type, signal, stack)
        return NativeCrash(
            exceptionType = type,
            signal = signal,
            exceptionMessage = message,
            stackTrace = stack,
            timestampMs = timestamp,
            platform = (record["platform"] as? String)?.takeIf { it.isNotEmpty() } ?: PLATFORM,
            fingerprint = fingerprint
        )
    }

    /**
     * The CRASH event, in the wire shape CrashHandler persists: timestamp is
     * the time of death (or [nowMs] when unknown), `fatal`, `title`
     * (`SIGNAL: Fatal signal 11 (SIGSEGV)`), and `metadata` with the
     * fingerprint, the platform and, when known, the signal number.
     */
    fun toEvent(crash: NativeCrash, nowMs: Long, isoTimestamp: (Long) -> String): Map<String, Any?> {
        val title = if (crash.exceptionMessage.isEmpty()) crash.exceptionType
                    else "${crash.exceptionType}: ${crash.exceptionMessage}"
        val metadata = LinkedHashMap<String, Any?>()
        metadata["fingerprint"] = crash.fingerprint
        metadata["platform"] = crash.platform
        if (crash.signal != null) metadata["signal"] = crash.signal
        return linkedMapOf(
            "type"             to "CRASH",
            "timestamp"        to isoTimestamp(crash.timestampMs ?: nowMs),
            "exceptionType"    to crash.exceptionType,
            "exceptionMessage" to crash.exceptionMessage,
            "stackTrace"       to (crash.stackTrace ?: ""),
            "breadcrumbs"      to emptyList<Any>(),
            "fatal"            to true,
            "title"            to title.take(200),
            "metadata"         to metadata,
            "screen"           to "",
            "x"                to 0.0,
            "y"                to 0.0,
            "capturedOffline"  to false,
            "networkAtCapture" to ""
        )
    }
}

/** The file the signal handler writes: `files/unilitix/native_crash.json`. */
internal object NativeCrashFile {
    const val DIRECTORY = "unilitix"
    const val NAME = "native_crash.json"

    fun locate(filesDir: File): File = File(File(filesDir, DIRECTORY), NAME)

    /**
     * Reads and deletes the record left by an earlier process, so it is
     * reported exactly once. Null when there is none.
     */
    fun consume(file: File): String? {
        if (!file.isFile) return null
        val text = try {
            file.readText(Charsets.UTF_8)
        } catch (e: Exception) {
            null
        }
        file.delete()
        return text?.takeIf { it.isNotBlank() }
    }
}

/**
 * Just enough JSON for a crash record: an object of strings, numbers,
 * booleans, nulls, and (skipped into maps and lists) nested values. Pure
 * Kotlin so it runs in JVM unit tests, where org.json is a stub.
 */
internal class MiniJson(private val s: String) {
    private var i = 0

    /** The top-level object, or null when the text is not one. */
    fun readObject(): Map<String, Any?>? {
        skipWs()
        if (i >= s.length || s[i] != '{') return null
        @Suppress("UNCHECKED_CAST")
        val value = readValue() as Map<String, Any?>
        skipWs()
        require(i == s.length) { "trailing data" }
        return value
    }

    private fun readValue(): Any? {
        skipWs()
        require(i < s.length) { "unexpected end" }
        return when (val c = s[i]) {
            '{' -> readMap()
            '[' -> readList()
            '"' -> readString()
            't' -> literal("true", true)
            'f' -> literal("false", false)
            'n' -> literal("null", null)
            else -> if (c == '-' || c in '0'..'9') readNumber() else throw IllegalArgumentException("bad value")
        }
    }

    private fun readMap(): Map<String, Any?> {
        val map = LinkedHashMap<String, Any?>()
        i++ // {
        skipWs()
        if (peek() == '}') { i++; return map }
        while (true) {
            skipWs()
            require(peek() == '"') { "expected key" }
            val key = readString()
            skipWs()
            require(peek() == ':') { "expected :" }
            i++
            map[key] = readValue()
            skipWs()
            when (peek()) {
                ',' -> i++
                '}' -> { i++; return map }
                else -> throw IllegalArgumentException("expected , or }")
            }
        }
    }

    private fun readList(): List<Any?> {
        val list = ArrayList<Any?>()
        i++ // [
        skipWs()
        if (peek() == ']') { i++; return list }
        while (true) {
            list.add(readValue())
            skipWs()
            when (peek()) {
                ',' -> i++
                ']' -> { i++; return list }
                else -> throw IllegalArgumentException("expected , or ]")
            }
        }
    }

    private fun readString(): String {
        i++ // opening quote
        val sb = StringBuilder()
        while (true) {
            require(i < s.length) { "unterminated string" }
            val c = s[i++]
            when (c) {
                '"' -> return sb.toString()
                '\\' -> {
                    require(i < s.length) { "bad escape" }
                    when (val e = s[i++]) {
                        '"', '\\', '/' -> sb.append(e)
                        'b' -> sb.append('\b')
                        'f' -> sb.append('\u000C')
                        'n' -> sb.append('\n')
                        'r' -> sb.append('\r')
                        't' -> sb.append('\t')
                        'u' -> {
                            require(i + 4 <= s.length) { "bad unicode escape" }
                            val code = s.substring(i, i + 4).toIntOrNull(16)
                                ?: throw IllegalArgumentException("bad unicode escape")
                            sb.append(code.toChar())
                            i += 4
                        }
                        else -> throw IllegalArgumentException("bad escape")
                    }
                }
                else -> sb.append(c)
            }
        }
    }

    private fun readNumber(): Number {
        val start = i
        if (peek() == '-') i++
        while (i < s.length && (s[i].isDigit() || s[i] in ".eE+-")) i++
        val text = s.substring(start, i)
        return text.toLongOrNull() ?: text.toDoubleOrNull() ?: throw IllegalArgumentException("bad number")
    }

    private fun literal(word: String, value: Any?): Any? {
        require(s.startsWith(word, i)) { "bad literal" }
        i += word.length
        return value
    }

    private fun peek(): Char? = if (i < s.length) s[i] else null

    private fun skipWs() {
        while (i < s.length && s[i].isWhitespace()) i++
    }
}
