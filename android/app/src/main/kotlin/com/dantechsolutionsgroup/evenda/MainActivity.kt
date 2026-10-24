package com.dantechsolutionsgroup.evenda

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ContentResolver
import android.content.Context
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
    private var player: MediaPlayer? = null
    private val handler = Handler(Looper.getMainLooper())
    private val stopRinging = Runnable { stopAlert() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannels()
    }

    /**
     * "evenda/alert": the call-style alert for an incoming Evenda Now request
     * while the app is open. ring() loops the Evenda alert and a call-like
     * vibration, following the phone's ringer mode (silent: nothing; vibrate:
     * vibration only), and stops by itself after 30 s; stop() ends it.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "evenda/alert").setMethodCallHandler { call, result ->
            when (call.method) {
                "ring" -> { startAlert(); result.success(null) }
                "stop" -> { stopAlert(); result.success(null) }
                else -> result.notImplemented()
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
        stopAlert() // leaving the app silences the alert
        super.onPause()
    }

    /**
     * Push channels. The send-push Edge Function picks one per message:
     *  evenda_urgent_v2  — Evenda Now requests and offers, critical reminders.
     *                      High importance (pops up) with the longer Evenda alert.
     *  evenda_default_v2 — bookings, quotes, reminders, supplier updates,
     *                      with the short Evenda chime.
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
            NotificationChannel("evenda_default_v2", "Bookings and reminders", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "Quotes, bookings, task reminders and supplier updates"
                setSound(sound("evenda_chime"), audio)
            }
        )
    }
}
