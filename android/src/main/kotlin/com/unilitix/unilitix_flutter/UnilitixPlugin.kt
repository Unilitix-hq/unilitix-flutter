package com.unilitix.unilitix_flutter

import android.content.Context
import android.os.BatteryManager
import android.os.Build
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.telephony.TelephonyManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class UnilitixPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var context: Context
    private var eventSink: EventChannel.EventSink? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "com.unilitix/sdk")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "com.unilitix/network")
        eventChannel.setStreamHandler(this)
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
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        eventSink = sink
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

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

        // 3-argument overload (handler) requires API 26+
        if (android.os.Build.VERSION.SDK_INT >= 26) {
            cm.registerNetworkCallback(request, networkCallback!!, mainHandler)
        } else {
            cm.registerNetworkCallback(request, networkCallback!!)
        }

        // Emit current state immediately
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

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }
}
