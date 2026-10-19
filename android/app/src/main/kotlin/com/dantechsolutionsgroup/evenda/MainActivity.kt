package com.dantechsolutionsgroup.evenda

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ContentResolver
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannels()
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
