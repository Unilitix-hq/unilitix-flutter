package com.unilitix.unilitix_flutter

import android.app.Activity
import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.unilitix.sdk.Unilitix
import io.unilitix.sdk.UnilitixConsent
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * The Android side of the Unilitix Flutter SDK (3.0.0): a thin bridge to
 * the native Android SDK (`com.unilitix:unilitix-android`), which owns
 * sessions, identity, consent, the offline queue, uploads, device and
 * network context, JVM/NDK crashes and ANRs.
 *
 * Dart sends what only Dart can see: route names (`screen`), Dart errors
 * (`recordError` → `recordExternalError(platform = "dart")`), taps with
 * Flutter's privacy rules (`recordTap`), wireframe snapshots
 * (`addSnapshot` → `addExternalSnapshot`) and masked screenshots, which
 * this plugin draws with PixelCopy and hands to `captureExternalScreenshot`.
 *
 * Channel `com.unilitix/sdk`. Every handler answers on the main thread and
 * never throws into Flutter.
 */
class UnilitixPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: Activity? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    /** Image work (scaling, masks, JPEG) and frame hand-off, off the main thread. */
    private val imageExecutor = Executors.newSingleThreadExecutor { r -> Thread(r, "unilitix-image") }

    /**
     * Dart errors. A fatal one is persisted synchronously by the native SDK
     * (bounded by the contract's fatal budget); that wait must not block the
     * main thread, since a Dart CRASH does not end the process.
     */
    private val errorExecutor = Executors.newSingleThreadExecutor { r -> Thread(r, "unilitix-error") }

    /** Power-outage contribution: file, preferences, WorkManager and network work. */
    private val powerExecutor = Executors.newSingleThreadExecutor { r -> Thread(r, "unilitix-power") }
    private var powerReceiver: BroadcastReceiver? = null

    /** Encoded frames waiting for Dart's commit or discard (see captureScreenshot). */
    private val pendingFrames = PendingFrames()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            handle(call, result)
        } catch (t: Throwable) {
            result.error("UNILITIX_ERROR", "${call.method}: ${t.javaClass.simpleName}: ${t.message}", null)
        }
    }

    private fun handle(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        when (call.method) {
            "init" -> init(args, result)
            "track" -> {
                Unilitix.trackEvent(args.string("name") ?: "", args.mapArg("properties").nonNull())
                result.success(null)
            }
            "screen" -> {
                args.string("name")?.let { Unilitix.trackScreen(it) }
                result.success(null)
            }
            "identify" -> {
                args.string("userId")?.let { Unilitix.identify(it, args.mapArg("traits").nonNull()) }
                result.success(null)
            }
            "reset" -> { Unilitix.reset(); result.success(null) }
            "flush" -> { Unilitix.flush(); result.success(null) }
            "startSession" -> { Unilitix.startSession(); result.success(null) }
            "endSession" -> { Unilitix.endSession(); result.success(null) }
            "setConsent" -> {
                UnilitixConsent.fromValue(args.string("consent"))?.let { Unilitix.setConsent(it) }
                result.success(null)
            }
            "addBreadcrumb" -> {
                Unilitix.addBreadcrumb(args.string("message") ?: "", args.string("category") ?: "custom")
                result.success(null)
            }
            "recordError" -> {
                val type = args.string("type") ?: "Error"
                val message = args.string("message") ?: ""
                val stack = args.string("stackTrace")
                val fatal = args["fatal"] == true
                val platform = args.string("platform") ?: "dart"
                val fingerprint = args.string("fingerprint")
                @Suppress("UNCHECKED_CAST")
                val metadata = (args["metadata"] as? Map<String, Any?>)?.takeIf { it.isNotEmpty() }
                errorExecutor.execute {
                    try {
                        Unilitix.recordExternalError(type, message, stack, fatal, platform, fingerprint, metadata)
                    } catch (_: Throwable) {
                    }
                }
                result.success(null)
            }
            // Taps come from Dart on Android (see init: the native tracker
            // would name every Flutter screen after the Activity). `type` is
            // TAP or RAGE_TAP; x/y are logical pixels, absent inside a
            // UnilitixPrivate area. The core stamps the current screen (the
            // last trackScreen).
            "recordTap" -> {
                val type = if (args.string("type") == "RAGE_TAP") "RAGE_TAP" else "TAP"
                Unilitix.recordExternalInteraction(type, args.number("x")?.toDouble(), args.number("y")?.toDouble())
                result.success(null)
            }
            "replayState" -> result.success(state())
            "addSnapshot" -> {
                args.string("json")?.let { Unilitix.addExternalSnapshot(it) }
                result.success(null)
            }
            "captureScreenshot" -> captureScreenshot(args, result)
            "commitScreenshot" -> {
                val frame = pendingFrames.take(args.number("id")?.toInt() ?: -1)
                if (frame != null) {
                    val width = args.number("width")?.toInt() ?: frame.width
                    val height = args.number("height")?.toInt() ?: frame.height
                    val ts = args.number("timestampMs")?.toLong() ?: System.currentTimeMillis()
                    val screen = args.string("screen")
                    imageExecutor.execute {
                        try {
                            Unilitix.captureExternalScreenshot(frame.jpeg, width, height, ts, screen)
                        } catch (_: Throwable) {
                        }
                    }
                }
                result.success(null)
            }
            "discardScreenshot" -> {
                pendingFrames.take(args.number("id")?.toInt() ?: -1)
                result.success(null)
            }
            // Power-outage contribution (opt-in, Flutter-only). Dart sends
            // enabled=true only when the app set the config flag and consent
            // is granted; anything else disables and deletes everything.
            "powerConfigure" -> {
                powerExecutor.execute {
                    try {
                        PowerContribution.configure(context, args)
                    } catch (_: Throwable) {
                    }
                    mainHandler.post {
                        updatePowerReceiver()
                        result.success(null)
                    }
                }
            }
            "powerUploadNow" -> {
                powerExecutor.execute {
                    val outcome = try {
                        PowerContribution.appendSample(context)
                        PowerContribution.upload(context)
                    } catch (_: Throwable) {
                        null
                    }
                    mainHandler.post { result.success(outcome) }
                }
            }
            else -> result.notImplemented()
        }
    }

    // -------------------------------------------------------------------------
    // Init
    // -------------------------------------------------------------------------

    private fun init(args: Map<*, *>, result: Result) {
        val apiKey = args.string("apiKey")
        if (apiKey.isNullOrEmpty()) {
            result.error("MISSING_API_KEY", "apiKey is required", null)
            return
        }
        val application = context as? Application ?: context.applicationContext as? Application
        if (application == null) {
            result.error("NO_APPLICATION", "the plugin has no Application context", null)
            return
        }
        val consent = UnilitixConsent.fromValue(args.string("consent")) ?: UnilitixConsent.GRANTED
        val config = args.mapArg("config")
        val wrapperName = args.string("wrapperName") ?: "flutter"
        val wrapperVersion = args.string("wrapperVersion") ?: ""

        // Before init, so the first session already reports the wrapper and
        // the native screenshot/snapshot capturers (which would only see one
        // FlutterView) never start: Dart supplies the frames.
        Unilitix.setWrapper(wrapperName, wrapperVersion)
        Unilitix.setExternalScreenCapture(true)
        Unilitix.init(application, apiKey, consent) { NativeConfig.apply(this, config) }
        if (!Unilitix.isInitialized) {
            result.error("INIT_FAILED", "the native SDK did not start (see the Unilitix log)", null)
            return
        }
        // Idempotent; covers a core that applies them to the live instance only.
        Unilitix.setWrapper(wrapperName, wrapperVersion)
        Unilitix.setExternalScreenCapture(true)
        activity?.let { Unilitix.attachToActivity(it) }
        result.success(state())
    }

    /** What Dart needs to drive capture: consent, session, sampling, who reports taps. */
    private fun state(): Map<String, Any?> = mapOf(
        "consent" to Unilitix.consent.value,
        "sessionId" to Unilitix.currentSessionId(),
        "replaySampled" to Unilitix.isReplaySampled(),
        "dartTaps" to true,
    )

    // -------------------------------------------------------------------------
    // Screenshot via PixelCopy (API 26+)
    //
    // PixelCopy reads from the window compositor, so it works with Impeller
    // and Vulkan. Everything after the copy (downscale, occlusion boxes, JPEG)
    // runs on a background thread. The encoded frame stays here until Dart
    // has checked its masks did not move during the capture: Dart then
    // commits it (handed to the native SDK) or discards it. Arguments:
    //   maxWidth  Int     target width in px (aspect preserved)
    //   quality   Int     JPEG quality 1..100
    //   scale     Double  logical px -> window px (devicePixelRatio)
    //   masks     List<List<Double>>  [left, top, right, bottom], logical px
    // Answers {id, width, height} (pixels of the encoded frame) or null.
    // -------------------------------------------------------------------------

    @Suppress("NewApi")
    private fun captureScreenshot(args: Map<*, *>, result: Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(null) // no PixelCopy for windows before API 26
            return
        }
        val act = activity ?: run { result.success(null); return }
        val window = act.window ?: run { result.success(null); return }
        val decorView = window.decorView
        if (decorView.width <= 0 || decorView.height <= 0) {
            result.success(null)
            return
        }
        val maxWidth = args.number("maxWidth")?.toInt() ?: 480
        val quality = (args.number("quality")?.toInt() ?: 30).coerceIn(1, 100)
        val scale = args.number("scale")?.toDouble() ?: 1.0
        val masks = (args["masks"] as? List<*>)?.mapNotNull { m ->
            (m as? List<*>)?.mapNotNull { (it as? Number)?.toDouble() }?.takeIf { it.size >= 4 }
        } ?: emptyList()

        val bitmap = Bitmap.createBitmap(decorView.width, decorView.height, Bitmap.Config.ARGB_8888)
        try {
            PixelCopy.request(window, bitmap, { copyResult ->
                if (copyResult != PixelCopy.SUCCESS) {
                    bitmap.recycle()
                    result.success(null)
                    return@request
                }
                imageExecutor.execute {
                    val frame = try {
                        processBitmap(bitmap, maxWidth, quality, scale, masks)
                    } catch (_: Throwable) {
                        null
                    } finally {
                        bitmap.recycle()
                    }
                    val answer = frame?.let {
                        val id = pendingFrames.put(it)
                        mapOf("id" to id, "width" to it.width, "height" to it.height)
                    }
                    mainHandler.post { result.success(answer) }
                }
            }, mainHandler)
        } catch (_: Exception) {
            bitmap.recycle()
            result.success(null)
        }
    }

    /** Downscale, paint occlusion boxes, encode JPEG. Runs off the main thread. */
    private fun processBitmap(
        src: Bitmap, maxWidth: Int, quality: Int, scale: Double, masks: List<List<Double>>
    ): EncodedFrame {
        var bmp = src
        var factor = 1.0
        if (maxWidth > 0 && src.width > maxWidth) {
            factor = maxWidth.toDouble() / src.width
            val h = (src.height * factor).toInt().coerceAtLeast(1)
            bmp = Bitmap.createScaledBitmap(src, maxWidth, h, true)
        }
        if (masks.isNotEmpty()) {
            if (bmp === src) bmp = src.copy(Bitmap.Config.ARGB_8888, true)
            val canvas = Canvas(bmp)
            val paint = Paint().apply { color = Color.BLACK; style = Paint.Style.FILL }
            val k = scale * factor // logical px -> output px
            for (m in masks) {
                val r = Rect(
                    ((m[0] * k) - 1).toInt().coerceIn(0, bmp.width),
                    ((m[1] * k) - 1).toInt().coerceIn(0, bmp.height),
                    ((m[2] * k) + 1).toInt().coerceIn(0, bmp.width),
                    ((m[3] * k) + 1).toInt().coerceIn(0, bmp.height),
                )
                if (r.width() > 0 && r.height() > 0) canvas.drawRect(r, paint)
            }
        }
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, quality, out)
        val frame = EncodedFrame(out.toByteArray(), bmp.width, bmp.height)
        if (bmp !== src) bmp.recycle()
        return frame
    }

    // -------------------------------------------------------------------------
    // ActivityAware — PixelCopy needs the Window; a late init attaches the SDK
    // -------------------------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        if (Unilitix.isInitialized) Unilitix.attachToActivity(binding.activity)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        if (Unilitix.isInitialized) Unilitix.attachToActivity(binding.activity)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        imageExecutor.shutdown()
        errorExecutor.shutdown()
        unregisterPowerReceiver()
        powerExecutor.shutdown()
        pendingFrames.clear()
    }

    /** Main thread. Registers the runtime power receiver when enabled, removes it otherwise. */
    private fun updatePowerReceiver() {
        if (PowerContribution.isEnabled(context)) {
            if (powerReceiver == null) powerReceiver = PowerContribution.registerRuntimeReceiver(context)
        } else {
            unregisterPowerReceiver()
        }
    }

    private fun unregisterPowerReceiver() {
        val r = powerReceiver ?: return
        powerReceiver = null
        try {
            context.unregisterReceiver(r)
        } catch (_: Throwable) {
        }
    }

    companion object {
        const val CHANNEL = "com.unilitix/sdk"
    }
}

/** A JPEG ready for the native SDK, with its pixel size. */
internal class EncodedFrame(val jpeg: ByteArray, val width: Int, val height: Int)

/**
 * Frames captured but not yet committed or discarded by Dart. At most
 * [MAX] are kept (Dart has one capture in flight at a time; an orphan from
 * a lost answer is dropped by the next ones). Thread-safe.
 */
internal class PendingFrames {
    private val frames = LinkedHashMap<Int, EncodedFrame>()
    private var nextId = 1

    @Synchronized
    fun put(frame: EncodedFrame): Int {
        val id = nextId++
        frames[id] = frame
        while (frames.size > MAX) frames.remove(frames.keys.first())
        return id
    }

    @Synchronized
    fun take(id: Int): EncodedFrame? = frames.remove(id)

    @Synchronized
    fun clear() = frames.clear()

    @get:Synchronized
    val size: Int get() = frames.size

    companion object {
        const val MAX = 2
    }
}

internal fun Map<*, *>.string(key: String): String? = this[key] as? String

internal fun Map<*, *>.number(key: String): Number? = this[key] as? Number

internal fun Map<*, *>.mapArg(key: String): Map<*, *> = this[key] as? Map<*, *> ?: emptyMap<String, Any?>()

/**
 * String-keyed, without null values (the Android SDK takes `Map<String, Any>`;
 * a null property carries nothing on the wire).
 */
internal fun Map<*, *>.nonNull(): Map<String, Any> {
    val out = LinkedHashMap<String, Any>(size)
    for ((k, v) in this) {
        if (k is String && v != null) out[k] = v
    }
    return out
}
