// VENDORED from unilitix-android 1.9.0 (unilitix-sdk/src/main/java/io/unilitix/sdk/core/Fingerprint.kt) by scripts/sync-android-native.sh.
// Do not edit here; change the Android SDK and re-run the script.

package io.unilitix.flutter.nativecrash

/**
 * A stable id for "this bug", so the dashboard counts one crash once across
 * devices: the exception type plus the first three stack frames with line
 * and column numbers removed. Mirrors `CrashTracker.fingerprint` in the
 * Flutter SDK (same hash, same normalisation) so a bug seen through both
 * SDKs groups the same way.
 *
 * Handles JVM frames (`at com.foo.Bar.baz(Bar.kt:12)`), Hermes / JavaScript
 * frames (`at baz (address at index.android.bundle:1:2345)`) and Dart
 * frames (`#0 Foo.bar (package:app/foo.dart:12:5)`).
 *
 * JVM frames must start with `at`: otherwise a message line such as
 * `TypeError: x is not an object (evaluating 'a.b')` counts as a frame and
 * the fingerprint changes with the message. The reference implementation and
 * test vectors are in the api repo (internal/sdkcontract/fingerprint.go).
 */
internal object Fingerprint {

    private val jvmLine = Regex("""^at\s+(.*?)\(([^:()]+)(?::\d+)?\)$""")
    private val jsLine = Regex("""^at\s+(.*?)\s*\((.*?)(?::\d+)+\)$""")
    private val dartLine = Regex("""^#\d+\s+(.*?)\s*\((.*?)(?::\d+)+\)$""")
    private val dartVirt = Regex("""virt\s+([0-9a-f]+)""")
    private val lineCol = Regex(""":\d+(:\d+)?$""")

    fun of(exceptionType: String, stackTrace: String?): String {
        val parts = mutableListOf(exceptionType)
        if (stackTrace != null) {
            var taken = 0
            for (raw in stackTrace.lineSequence()) {
                if (taken == 3) break
                val line = raw.trim()
                if (line.isEmpty()) continue
                val frame = normalise(line) ?: continue
                parts.add(frame)
                taken++
            }
        }
        return fnv1a64(parts.joinToString("|"))
    }

    /** One frame with its location stripped of line/column, or null if the line is not a frame. */
    internal fun normalise(line: String): String? {
        dartVirt.find(line)?.let { return "virt:${it.groupValues[1]}" }
        dartLine.matchEntire(line)?.let { return "${it.groupValues[1]} (${it.groupValues[2]})" }
        jsLine.matchEntire(line)?.let { return "${it.groupValues[1]} (${it.groupValues[2]})" }
        jvmLine.matchEntire(line)?.let { return "${it.groupValues[1]}(${it.groupValues[2]})" }
        // A frame without parentheses (Hermes "at foo:1:2" or bare addresses).
        if (line.startsWith("at ")) return line.removePrefix("at ").replace(lineCol, "").trim()
        return null
    }

    /** Two 32-bit FNV-1a hashes with different seeds, as the Flutter SDK does. */
    private fun fnv1a64(s: String): String {
        val bytes = s.toByteArray(Charsets.UTF_8)
        val a = fnv1a32(bytes, 0x811c9dc5L)
        val b = fnv1a32(bytes, 0x811c9dc5L xor 0x5bd1e995L)
        return "%08x%08x".format(a, b)
    }

    private fun fnv1a32(bytes: ByteArray, seed: Long): Long {
        var h = seed
        for (byte in bytes) {
            h = h xor (byte.toLong() and 0xff)
            h = (h * 16777619L) and 0xffffffffL
        }
        return h
    }
}
