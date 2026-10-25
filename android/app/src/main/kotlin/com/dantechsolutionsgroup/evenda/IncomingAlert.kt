package com.dantechsolutionsgroup.evenda

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build

/**
 * Call-style alert for an Evenda Now request when Evenda is closed or in the
 * background (the open app shows its own screen).
 *
 * The notification rings again and again until answered (FLAG_INSISTENT), opens
 * full screen over the lock screen like an incoming call (full-screen intent),
 * and offers "Make an offer" / "Not now". It cancels itself after 45 s.
 *
 * Android 14+ only lets an app open full screen if the user allows it
 * (Settings → Apps → Evenda → full-screen notifications); otherwise Android
 * shows it as a ringing pop-up instead. Evenda's notification settings link there.
 */
object IncomingAlert {
    const val CHANNEL = "evenda_incoming_v1"
    const val EXTRA_ROUTE = "evenda_route"
    private const val TAG = "now-incoming"

    fun id(requestId: String) = requestId.hashCode()

    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Incoming Evenda Now requests", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Rings like a call when a supplier nearby is asked for stock you have"
                setSound(
                    Uri.parse("${ContentResolver.SCHEME_ANDROID_RESOURCE}://${context.packageName}/raw/evenda_urgent"),
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build(),
                )
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 400, 200, 400, 1000, 400, 200, 400)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                enableLights(true)
                lightColor = 0xFF996633.toInt()
            },
        )
    }

    private fun open(context: Context, route: String, requestCode: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .putExtra(EXTRA_ROUTE, route)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(context, requestCode, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    fun show(context: Context, data: Map<String, String>) {
        val requestId = data["request_id"] ?: return
        ensureChannel(context)
        val n = id(requestId)
        val incoming = open(context, "/now/incoming/$requestId", n)
        val offer = open(context, "/now/respond/$requestId", n + 1)
        val notNow = PendingIntent.getBroadcast(
            context, n + 2,
            Intent(context, IncomingAlertReceiver::class.java).putExtra("request_id", requestId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(context, CHANNEL) else Notification.Builder(context)
        builder
            .setSmallIcon(R.drawable.ic_stat_evenda)
            .setColor(0xFF1B3B22.toInt())
            .setContentTitle(data["title"] ?: "Urgent request near you")
            .setContentText(data["body"] ?: "A vendor nearby needs stock you have. Tap to see it.")
            .setStyle(Notification.BigTextStyle().bigText(data["body"] ?: ""))
            .setCategory(Notification.CATEGORY_REMINDER)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            .setContentIntent(incoming)
            .setFullScreenIntent(incoming, true)
            .addAction(Notification.Action.Builder(null, "Not now", notNow).build())
            .addAction(Notification.Action.Builder(null, "Make an offer", offer).build())
        // Unread count for the app icon badge (launchers that show numbers).
        data["unread"]?.toIntOrNull()?.takeIf { it > 0 }?.let { builder.setNumber(it) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) builder.setTimeoutAfter(45_000)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            builder.setPriority(Notification.PRIORITY_MAX).setVibrate(longArrayOf(0, 400, 200, 400, 1000))
                .setSound(Uri.parse("${ContentResolver.SCHEME_ANDROID_RESOURCE}://${context.packageName}/raw/evenda_urgent"))
        }
        val notification = builder.build().apply { flags = flags or Notification.FLAG_INSISTENT }
        context.getSystemService(NotificationManager::class.java)?.notify(TAG, n, notification)
    }

    fun cancel(context: Context, requestId: String) {
        context.getSystemService(NotificationManager::class.java)?.cancel(TAG, id(requestId))
    }

    /** Stops every ringing request alert (the app took over, or the user answered). */
    fun cancelAll(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            manager.activeNotifications.filter { it.tag == TAG }.forEach { manager.cancel(TAG, it.id) }
        }
    }
}

/** "Not now" on the notification: stop ringing; the request stays in Evenda Now. */
class IncomingAlertReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        intent.getStringExtra("request_id")?.let { IncomingAlert.cancel(context, it) }
    }
}
