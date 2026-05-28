package com.unilitix.unilitix_flutter

import android.app.Application
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.unilitix.sdk.Unilitix

class UnilitixPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {

    private lateinit var channel: MethodChannel
    private var application: Application? = null

    override fun onAttachedToEngine(
        binding: FlutterPlugin.FlutterPluginBinding
    ) {
        channel = MethodChannel(binding.binaryMessenger, "com.unilitix/sdk")
        channel.setMethodCallHandler(this)
        application = binding.applicationContext as? Application
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {

            "init" -> {
                val apiKey = call.argument<String>("apiKey")
                    ?: return result.error("MISSING_API_KEY", "apiKey is required", null)
                val app = application
                    ?: return result.error("NO_CONTEXT", "Application context not available", null)
                try {
                    Unilitix.init(app, apiKey) {
                        call.argument<String>("endpoint")?.let { apiUrl = it }
                        call.argument<Boolean>("debug")?.let { debugLogging = it }
                        call.argument<Boolean>("autoTrackScreens")?.let { autoTrackScreens = it }
                        call.argument<Boolean>("autoTrackTaps")?.let { autoTrackTaps = it }
                        call.argument<Boolean>("autoTrackCrashes")?.let { autoTrackCrashes = it }
                        call.argument<Boolean>("autoTrackRageTaps")?.let { autoTrackRageTaps = it }
                        call.argument<Int>("flushIntervalSeconds")?.let { flushIntervalSeconds = it }
                        call.argument<Int>("sessionTimeoutSeconds")?.let { sessionTimeoutSeconds = it }
                        call.argument<Boolean>("maskInputs")?.let { maskInputs = it }
                        call.argument<Double>("sampleRate")?.let { sampleRate = it }
                    }
                    result.success(null)
                } catch (e: Exception) {
                    result.error("INIT_ERROR", e.message, null)
                }
            }

            "track" -> {
                val event = call.argument<String>("event")
                    ?: return result.error("MISSING_EVENT", "event is required", null)
                val props = call.argument<Map<String, Any>>("properties") ?: emptyMap()
                try {
                    Unilitix.trackEvent(event, props)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("TRACK_ERROR", e.message, null)
                }
            }

            "screen" -> {
                val name = call.argument<String>("screenName")
                    ?: return result.error("MISSING_SCREEN", "screenName is required", null)
                try {
                    Unilitix.trackScreen(name)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("SCREEN_ERROR", e.message, null)
                }
            }

            "identify" -> {
                val userId = call.argument<String>("userId")
                    ?: return result.error("MISSING_USER_ID", "userId is required", null)
                val traits = call.argument<Map<String, Any>>("traits") ?: emptyMap()
                try {
                    Unilitix.identify(userId, traits)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("IDENTIFY_ERROR", e.message, null)
                }
            }

            "startSession" -> {
                try {
                    Unilitix.startSession()
                    result.success(null)
                } catch (e: Exception) {
                    result.error("SESSION_ERROR", e.message, null)
                }
            }

            "endSession" -> {
                try {
                    Unilitix.endSession()
                    result.success(null)
                } catch (e: Exception) {
                    result.error("SESSION_ERROR", e.message, null)
                }
            }

            "flush" -> {
                try {
                    Unilitix.flush()
                    result.success(null)
                } catch (e: Exception) {
                    result.error("FLUSH_ERROR", e.message, null)
                }
            }

            "optOut" -> {
                try {
                    Unilitix.optOut()
                    result.success(null)
                } catch (e: Exception) {
                    result.error("OPT_ERROR", e.message, null)
                }
            }

            "optIn" -> {
                try {
                    Unilitix.optIn()
                    result.success(null)
                } catch (e: Exception) {
                    result.error("OPT_ERROR", e.message, null)
                }
            }

            "reset" -> {
                try {
                    Unilitix.reset()
                    result.success(null)
                } catch (e: Exception) {
                    result.error("RESET_ERROR", e.message, null)
                }
            }

            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        application = binding.activity.application
    }

    override fun onDetachedFromActivity() {}
    override fun onDetachedFromActivityForConfigChanges() {}
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        application = binding.activity.application
    }
}
