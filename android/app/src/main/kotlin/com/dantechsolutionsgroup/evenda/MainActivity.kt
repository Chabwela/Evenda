package com.dantechsolutionsgroup.evenda

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.view.WindowManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        /** True while Evenda is on screen (then the app shows its own alert). */
        @Volatile var visible = false
    }

    private var channel: MethodChannel? = null
    private var launchRoute: String? = null
    private var player: MediaPlayer? = null
    private val handler = Handler(Looper.getMainLooper())
    private val stopRinging = Runnable { stopAlert() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannels()
        IncomingAlert.ensureChannel(this)
        handleAlertIntent(intent, cold = true)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleAlertIntent(intent, cold = false)
    }

    /** Opened from the call-style alert: show the screen it points to. */
    private fun handleAlertIntent(intent: Intent?, cold: Boolean) {
        val route = intent?.getStringExtra(IncomingAlert.EXTRA_ROUTE) ?: return
        intent.removeExtra(IncomingAlert.EXTRA_ROUTE)
        // The incoming screen shows over the lock screen like a call; after
        // answering, Evenda goes back behind the lock (setLocked(false) on stop).
        if (route.startsWith("/now/incoming/")) showOverLockScreen(true)
        if (cold || channel == null) launchRoute = route else channel?.invokeMethod("open", route)
    }

    private fun showOverLockScreen(on: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(on)
            setTurnScreenOn(on)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (on) window.addFlags(flags) else window.clearFlags(flags)
        }
    }

    override fun onResume() {
        super.onResume()
        visible = true
    }

    /**
     * "evenda/alert": the call-style alert for an incoming Evenda Now request
     * while the app is open. ring() loops the Evenda alert and a call-like
     * vibration, following the phone's ringer mode (silent: nothing; vibrate:
     * vibration only), and stops by itself after 30 s; stop() ends it.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "evenda/alert").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    // The app's own screen takes over from the ringing notification.
                    "ring" -> { IncomingAlert.cancelAll(this@MainActivity); startAlert(); result.success(null) }
                    "stop" -> { stopAlert(); showOverLockScreen(false); result.success(null) }
                    "launchRoute" -> { result.success(launchRoute); launchRoute = null }
                    "fullScreenAllowed" -> result.success(fullScreenAllowed())
                    "openFullScreenSettings" -> { openFullScreenSettings(); result.success(null) }
                    "openBatterySettings" -> { openBatterySettings(); result.success(null) }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun vibrator(): Vibrator? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
        else @Suppress("DEPRECATION") (getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator)

    private fun startAlert() {
        stopAlert()
        val mode = (getSystemService(Context.AUDIO_SERVICE) as? AudioManager)?.ringerMode ?: AudioManager.RINGER_MODE_NORMAL
        if (mode == AudioManager.RINGER_MODE_SILENT) return
        val pattern = longArrayOf(0, 400, 200, 400, 1000)
        vibrator()?.let { v ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) v.vibrate(VibrationEffect.createWaveform(pattern, 0))
            else @Suppress("DEPRECATION") v.vibrate(pattern, 0)
        }
        if (mode == AudioManager.RINGER_MODE_NORMAL) {
            player = MediaPlayer().apply {
                setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                setDataSource(this@MainActivity, Uri.parse("${ContentResolver.SCHEME_ANDROID_RESOURCE}://$packageName/raw/evenda_urgent"))
                isLooping = true
                setOnPreparedListener { it.start() }
                prepareAsync()
            }
        }
        handler.postDelayed(stopRinging, 30_000)
    }

    private fun stopAlert() {
        handler.removeCallbacks(stopRinging)
        player?.run { try { stop() } catch (_: IllegalStateException) {}; release() }
        player = null
        vibrator()?.cancel()
    }

    override fun onPause() {
        visible = false
        stopAlert() // leaving the app silences the alert
        super.onPause()
    }

    /** Android 14+ asks the user before an app may open full screen over the lock screen. */
    private fun fullScreenAllowed(): Boolean =
        if (Build.VERSION.SDK_INT >= 34) getSystemService(android.app.NotificationManager::class.java)?.canUseFullScreenIntent() ?: false else true

    private fun openFullScreenSettings() {
        val intent = if (Build.VERSION.SDK_INT >= 34)
            Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:$packageName"))
        else Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        try { startActivity(intent) } catch (_: Exception) { openAppSettings() }
    }

    /** Phone makers often stop closed apps from waking; this is where people allow it. */
    private fun openBatterySettings() {
        try { startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) } catch (_: Exception) { openAppSettings() }
    }

    private fun openAppSettings() {
        try { startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))) } catch (_: Exception) {}
    }

    /**
     * Push channels. The send-push Edge Function picks one per message:
     *  evenda_urgent_v2  — Evenda Now requests and offers, critical reminders.
     *                      High importance (pops up) with the longer Evenda alert.
     *  evenda_activity_v1 — quote requests, quotations, bookings and payments.
     *                      High importance (pops up) with the short Evenda chime.
     *  evenda_default_v2 — reminders and supplier updates, with the chime.
     * Android fixes a channel's sound when it is created, so changing a sound
     * means a new channel ID (and deleting the old one).
     */
    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val audio = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        fun sound(name: String): Uri = Uri.parse("${ContentResolver.SCHEME_ANDROID_RESOURCE}://$packageName/raw/$name")

        listOf("evenda_urgent", "evenda_default").forEach { manager.deleteNotificationChannel(it) }

        manager.createNotificationChannel(
            NotificationChannel("evenda_urgent_v2", "Urgent requests", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Evenda Now requests near you, offers on your requests and critical reminders"
                setSound(sound("evenda_urgent"), audio)
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 300, 180, 300, 180, 500)
                enableLights(true)
                lightColor = 0xFF996633.toInt()
            }
        )
        manager.createNotificationChannel(
            NotificationChannel("evenda_activity_v1", "Quotes and bookings", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Quote requests, quotations, bookings and payments"
                setSound(sound("evenda_chime"), audio)
                enableVibration(true)
            }
        )
        manager.createNotificationChannel(
            NotificationChannel("evenda_default_v2", "Reminders and updates", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Task reminders and supplier updates"
                setSound(sound("evenda_chime"), audio)
            }
        )
    }
}
