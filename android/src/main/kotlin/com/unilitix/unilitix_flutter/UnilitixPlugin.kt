package com.unilitix.unilitix_flutter

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.view.PixelCopy
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.TelephonyManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.util.concurrent.Executors

class UnilitixPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler, ActivityAware {
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var screenshotChannel: MethodChannel
    private lateinit var context: Context
    private var eventSink: EventChannel.EventSink? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var activity: Activity? = null

    /** Single background thread for image work so captures never contend with the UI thread. */
    private val imageExecutor = Executors.newSingleThreadExecutor { r -> Thread(r, "unilitix-image") }
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext

        methodChannel = MethodChannel(binding.binaryMessenger, "com.unilitix/sdk")
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, "com.unilitix/network")
        eventChannel.setStreamHandler(this)

        screenshotChannel = MethodChannel(binding.binaryMessenger, "unilitix/screenshot")
        screenshotChannel.setMethodCallHandler { call, result ->
            if (call.method == "captureScreenshot") {
                captureScreenshot(call, result)
            } else {
                result.notImplemented()
            }
        }

        NativeCrashHandler.install(context)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getBatteryLevel" -> {
                try {
                    val bm = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
                    val level = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
                    result.success(level.toDouble() / 100.0)
                } catch (e: Exception) { result.success(-1.0) }
            }
            "getCarrierName" -> {
                try {
                    val tm = context.getSystemService(Context.TELEPHONY_SERVICE)
                            as? TelephonyManager
                    result.success(tm?.networkOperatorName ?: "")
                } catch (e: Exception) {
                    result.success("")
                }
            }
            // Device fields the SDK used to get from device_info_plus. Served
            // from android.os.Build directly: no extra plugin, no extra dex.
            "getDeviceInfo" -> {
                result.success(mapOf(
                    "manufacturer" to (Build.MANUFACTURER ?: ""),
                    "model" to (Build.MODEL ?: ""),
                    "brand" to (Build.BRAND ?: ""),
                    "osVersion" to (Build.VERSION.RELEASE ?: ""),
                    "sdkInt" to Build.VERSION.SDK_INT,
                    "timezone" to java.util.TimeZone.getDefault().id,
                ))
            }
            // App fields the SDK used to get from package_info_plus.
            "getPackageInfo" -> {
                try {
                    val pm = context.packageManager
                    val pi = pm.getPackageInfo(context.packageName, 0)
                    val buildNumber = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        pi.longVersionCode.toString()
                    } else {
                        @Suppress("DEPRECATION") pi.versionCode.toString()
                    }
                    result.success(mapOf(
                        "appName" to context.applicationInfo.loadLabel(pm).toString(),
                        "packageName" to context.packageName,
                        "version" to (pi.versionName ?: ""),
                        "buildNumber" to buildNumber,
                    ))
                } catch (e: Exception) {
                    result.success(null)
                }
            }
            // Returns the JSON written by the uncaught-exception handler of a
            // previous process (or null), and clears it.
            "readNativeCrash" -> result.success(NativeCrashHandler.consume(context))
            else -> result.notImplemented()
        }
    }

    // -------------------------------------------------------------------------
    // Screenshot via PixelCopy (API 26+)
    //
    // PixelCopy reads from the window compositor — immune to Impeller/Vulkan
    // DEVICE_LOCAL texture issues. Everything after the copy (downscale,
    // occlusion boxes, JPEG encode) runs on a background thread, so the main
    // thread only pays for the copy itself. Arguments from Dart:
    //   maxWidth  Int     target width in px (aspect preserved)
    //   quality   Int     JPEG quality 1..100
    //   scale     Double  logical-px → window-px factor (devicePixelRatio)
    //   masks     List<List<Double>>  [left, top, right, bottom] in logical px
    // -------------------------------------------------------------------------

    @Suppress("NewApi")
    private fun captureScreenshot(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(null) // API < 26 — Dart fallback will handle it
            return
        }
        val act = activity ?: run { result.success(null); return }
        val window = act.window ?: run { result.success(null); return }
        val decorView = window.decorView
        if (decorView.width <= 0 || decorView.height <= 0) {
            result.success(null)
            return
        }

        val maxWidth = (call.argument<Number>("maxWidth") ?: 480).toInt()
        val quality = (call.argument<Number>("quality") ?: 30).toInt().coerceIn(1, 100)
        val scale = (call.argument<Number>("scale") ?: 1.0).toDouble()
        @Suppress("UNCHECKED_CAST")
        val masks = (call.argument<List<List<Number>>>("masks") ?: emptyList())

        val bitmap = Bitmap.createBitmap(decorView.width, decorView.height, Bitmap.Config.ARGB_8888)
        try {
            PixelCopy.request(window, bitmap, { copyResult ->
                if (copyResult != PixelCopy.SUCCESS) {
                    bitmap.recycle()
                    result.success(null)
                    return@request
                }
                imageExecutor.execute {
                    val bytes = try {
                        processBitmap(bitmap, maxWidth, quality, scale, masks)
                    } catch (e: Throwable) {
                        null
                    } finally {
                        bitmap.recycle()
                    }
                    mainHandler.post { result.success(bytes) }
                }
            }, mainHandler)
        } catch (e: Exception) {
            bitmap.recycle()
            result.success(null)
        }
    }

    /** Downscale, paint occlusion boxes, encode JPEG. Runs off the main thread. */
    private fun processBitmap(
        src: Bitmap, maxWidth: Int, quality: Int, scale: Double, masks: List<List<Number>>
    ): ByteArray {
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
                if (m.size < 4) continue
                val r = Rect(
                    ((m[0].toDouble() * k) - 1).toInt().coerceIn(0, bmp.width),
                    ((m[1].toDouble() * k) - 1).toInt().coerceIn(0, bmp.height),
                    ((m[2].toDouble() * k) + 1).toInt().coerceIn(0, bmp.width),
                    ((m[3].toDouble() * k) + 1).toInt().coerceIn(0, bmp.height),
                )
                if (r.width() > 0 && r.height() > 0) canvas.drawRect(r, paint)
            }
        }
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, quality, out)
        if (bmp !== src) bmp.recycle()
        return out.toByteArray()
    }

    // -------------------------------------------------------------------------
    // Network event channel
    // -------------------------------------------------------------------------

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        eventSink = sink
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        networkCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                sink?.success(getNetworkType(caps))
            }
            override fun onAvailable(network: Network) {
                val caps = cm.getNetworkCapabilities(network)
                sink?.success(if (caps != null) getNetworkType(caps) else "OFFLINE")
            }
            override fun onLost(network: Network) {
                sink?.success("OFFLINE")
            }
        }

        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()

        if (Build.VERSION.SDK_INT >= 26) {
            cm.registerNetworkCallback(request, networkCallback!!, mainHandler)
        } else {
            cm.registerNetworkCallback(request, networkCallback!!)
        }

        val active = cm.activeNetwork
        val caps = active?.let { cm.getNetworkCapabilities(it) }
        sink?.success(if (caps != null) getNetworkType(caps) else "OFFLINE")
    }

    override fun onCancel(arguments: Any?) {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        networkCallback?.let { cm.unregisterNetworkCallback(it) }
        networkCallback = null
        eventSink = null
    }

    private fun getNetworkType(caps: NetworkCapabilities): String {
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)     -> "WIFI"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ETHERNET"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> resolveCellular()
            else -> "UNKNOWN"
        }
    }

    private fun resolveCellular(): String {
        return try {
            val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
            val networkType = tm?.dataNetworkType
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                networkType == TelephonyManager.NETWORK_TYPE_NR) {
                "5G"
            } else {
                when (networkType) {
                    TelephonyManager.NETWORK_TYPE_LTE   -> "4G"
                    TelephonyManager.NETWORK_TYPE_HSDPA,
                    TelephonyManager.NETWORK_TYPE_HSUPA,
                    TelephonyManager.NETWORK_TYPE_HSPA,
                    TelephonyManager.NETWORK_TYPE_HSPAP,
                    TelephonyManager.NETWORK_TYPE_UMTS  -> "3G"
                    TelephonyManager.NETWORK_TYPE_EDGE,
                    TelephonyManager.NETWORK_TYPE_GPRS,
                    TelephonyManager.NETWORK_TYPE_CDMA  -> "2G"
                    else -> "CELLULAR"
                }
            }
        } catch (_: Exception) {
            "CELLULAR"
        }
    }

    // -------------------------------------------------------------------------
    // ActivityAware — required to access the Window for PixelCopy
    // -------------------------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        screenshotChannel.setMethodCallHandler(null)
        imageExecutor.shutdown()
    }
}

/**
 * Captures JVM-level uncaught exceptions (the ones Dart never sees: native
 * plugin crashes, OOM, platform-thread failures) to a marker file that the
 * SDK reads and reports as a fatal CRASH on the next launch. Chains to the
 * previously installed handler so the process still terminates normally.
 */
object NativeCrashHandler {
    private const val FILE_NAME = "unilitix_native_crash.json"
    @Volatile private var installed = false

    fun install(context: Context) {
        if (installed) return
        installed = true
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val sw = StringWriter()
                throwable.printStackTrace(PrintWriter(sw))
                val json = JSONObject()
                    .put("platform", "android")
                    .put("thread", thread.name)
                    .put("exceptionType", throwable.javaClass.name)
                    .put("exceptionMessage", throwable.message ?: "")
                    .put("stackTrace", sw.toString().take(16_000))
                    .put("timestamp", System.currentTimeMillis())
                File(context.filesDir, FILE_NAME).writeText(json.toString())
            } catch (_: Throwable) {
                // Never let crash reporting mask the real crash.
            }
            previous?.uncaughtException(thread, throwable)
        }
    }

    fun consume(context: Context): String? {
        return try {
            val f = File(context.filesDir, FILE_NAME)
            if (!f.exists()) return null
            val text = f.readText()
            f.delete()
            text
        } catch (_: Throwable) {
            null
        }
    }
}
