package com.unilitix.unilitix_flutter

import android.Manifest
import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.os.BatteryManager
import android.os.Build
import android.os.Process
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Android side of power-outage contribution (opt-in, see
 * `UnilitixConfig.powerOutageContribution`).
 *
 * Nothing here runs unless the Dart SDK has called `powerConfigure` with
 * `enabled: true`, which it does only when the app set the flag AND consent is
 * granted. While disabled the manifest receiver is disabled (its manifest
 * default), no work is scheduled, and the log file does not exist.
 *
 * The rules (log cap, 48 h window, 200-event batches, daily device hash, H3
 * cell, request outcomes) are in PowerSignals.java / PowerH3.java, which are
 * unit-tested on the JVM; this file is only Android glue.
 */
internal object PowerContribution {
    private const val PREFS = "unilitix_power"
    private const val K_ENABLED = "enabled"
    private const val K_API_KEY = "apiKey"
    private const val K_API_URL = "apiUrl"
    private const val K_INSTALL_ID = "installId"
    private const val K_SALT = "salt"
    private const val K_SDK_VERSION = "sdkVersion"
    const val WORK_NAME = "unilitix_power_upload"

    /** Serialises uploads from the worker and from the plugin's foreground trigger. */
    private val uploadLock = Any()

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** In the no-backup dir: never included in Auto Backup or device transfer. */
    fun logFile(context: Context): File = File(context.noBackupFilesDir, PowerSignals.FILE_NAME)

    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(K_ENABLED, false)

    /**
     * Applies the Dart side's decision. Enabling stores the upload settings,
     * enables the manifest receiver and schedules the periodic upload.
     * Disabling undoes all of it and deletes the log; an app that never
     * enabled the feature only pays one preferences read here.
     */
    fun configure(context: Context, args: Map<*, *>) {
        val enable = args["enabled"] == true
        val p = prefs(context)
        if (enable) {
            p.edit()
                .putBoolean(K_ENABLED, true)
                .putString(K_API_KEY, args["apiKey"] as? String)
                .putString(K_API_URL, args["apiUrl"] as? String)
                .putString(K_INSTALL_ID, args["installId"] as? String)
                .putString(K_SALT, args["salt"] as? String)
                .putString(K_SDK_VERSION, args["sdkVersion"] as? String)
                .commit()
            setReceiverEnabled(context, true)
            schedule(context)
        } else {
            if (p.getBoolean(K_ENABLED, false)) {
                p.edit().clear().commit()
                setReceiverEnabled(context, false)
                cancel(context)
            }
            PowerSignals.clear(logFile(context))
        }
    }

    private fun setReceiverEnabled(context: Context, enabled: Boolean) {
        try {
            val component = ComponentName(context, PowerConnectionReceiver::class.java)
            val state = if (enabled) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } else {
                // Back to the manifest default, which is android:enabled="false".
                PackageManager.COMPONENT_ENABLED_STATE_DEFAULT
            }
            if (context.packageManager.getComponentEnabledSetting(component) != state) {
                context.packageManager.setComponentEnabledSetting(
                    component, state, PackageManager.DONT_KILL_APP
                )
            }
        } catch (_: Throwable) {
        }
    }

    private fun schedule(context: Context) {
        try {
            val request = PeriodicWorkRequest.Builder(
                PowerUploadWorker::class.java, 15, TimeUnit.MINUTES
            ).setConstraints(
                Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
            ).build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request
            )
        } catch (_: Throwable) {
            // WorkManager unavailable (e.g. the app removed its initializer
            // without providing a Configuration): foreground uploads still run.
        }
    }

    private fun cancel(context: Context) {
        try {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
        } catch (_: Throwable) {
        }
    }

    fun appendTransition(context: Context, action: String?) {
        val type = when (action) {
            Intent.ACTION_POWER_CONNECTED -> "connect"
            Intent.ACTION_POWER_DISCONNECTED -> "disconnect"
            else -> return
        }
        if (!isEnabled(context)) return
        PowerSignals.append(logFile(context), type, System.currentTimeMillis(), null)
    }

    /** Records whether the device is plugged in right now (sticky battery intent; no receiver registered). */
    fun appendSample(context: Context) {
        if (!isEnabled(context)) return
        val battery = try {
            context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        } catch (_: Throwable) {
            null
        } ?: return
        val plugged = battery.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1)
        if (plugged < 0) return
        PowerSignals.append(logFile(context), "sample", System.currentTimeMillis(), plugged != 0)
    }

    /**
     * The freshest last-known fix from the network or passive provider, only
     * if the app itself holds a location permission. Never requests
     * permission, never starts location updates, no Play Services. The
     * coordinates stay on the device: only the res-7 H3 cell is sent.
     */
    @SuppressLint("MissingPermission")
    private fun lastKnownLocation(context: Context): Location? {
        val pid = Process.myPid()
        val uid = Process.myUid()
        val granted = context.checkPermission(Manifest.permission.ACCESS_COARSE_LOCATION, pid, uid) ==
            PackageManager.PERMISSION_GRANTED ||
            context.checkPermission(Manifest.permission.ACCESS_FINE_LOCATION, pid, uid) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) return null
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return null
        var best: Location? = null
        for (provider in listOf(LocationManager.NETWORK_PROVIDER, LocationManager.PASSIVE_PROVIDER)) {
            val l = try {
                lm.getLastKnownLocation(provider)
            } catch (_: Throwable) {
                null // SecurityException / unknown provider
            }
            if (l != null && (best == null || l.time > best.time)) best = l
        }
        return best
    }

    /** One upload pass. Blocking; call off the main thread. */
    fun upload(context: Context): String {
        synchronized(uploadLock) {
            val file = logFile(context)
            val p = prefs(context)
            if (!p.getBoolean(K_ENABLED, false)) {
                PowerSignals.clear(file)
                return PowerSignals.Outcome.NOT_CONFIGURED.name
            }
            val cfg = PowerSignals.Config(
                p.getString(K_API_KEY, null),
                p.getString(K_API_URL, null),
                p.getString(K_INSTALL_ID, null),
                p.getString(K_SALT, null),
                p.getString(K_SDK_VERSION, null) ?: "unknown",
            )
            val loc = lastKnownLocation(context)
            return PowerSignals.upload(
                file, cfg, loc?.latitude, loc?.longitude, loc?.time ?: 0L,
                System.currentTimeMillis(), PowerSignals.HttpTransport()
            ).name
        }
    }

    /**
     * Receiver registered at runtime while the plugin is attached and the
     * feature is enabled. Context-registered receivers are not subject to the
     * Android 8 manifest-receiver limits, so transitions are recorded at least
     * while the app process is alive; duplicates with the manifest receiver are
     * dropped by PowerSignals.append.
     */
    fun registerRuntimeReceiver(context: Context): BroadcastReceiver? {
        if (!isEnabled(context)) return null
        val receiver = PowerConnectionReceiver()
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_POWER_CONNECTED)
            addAction(Intent.ACTION_POWER_DISCONNECTED)
        }
        return try {
            if (Build.VERSION.SDK_INT >= 33) {
                context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                context.registerReceiver(receiver, filter)
            }
            receiver
        } catch (_: Throwable) {
            null
        }
    }
}

/**
 * Declared in the manifest with android:enabled="false" and enabled only when
 * the app opts in. Appends one line to the no-backup log and returns: no
 * Flutter engine, no network, no location.
 */
class PowerConnectionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        try {
            PowerContribution.appendTransition(context.applicationContext, intent.action)
        } catch (_: Throwable) {
            // Never crash the host app from a broadcast.
        }
    }
}

/** Periodic (15 min, network required) upload of the power log. */
class PowerUploadWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        try {
            val ctx = applicationContext
            if (!PowerContribution.isEnabled(ctx)) {
                PowerSignals.clear(PowerContribution.logFile(ctx))
                return Result.success()
            }
            PowerContribution.appendSample(ctx)
            PowerContribution.upload(ctx)
        } catch (_: Throwable) {
            // Retried on the next period; never crash the host app.
        }
        // Success either way: the next period is the retry, so WorkManager's
        // own backoff never stacks on top of it.
        return Result.success()
    }
}
