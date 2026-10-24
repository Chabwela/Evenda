package com.dantechsolutionsgroup.evenda

import com.google.firebase.messaging.RemoteMessage
import io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingService

/**
 * Firebase messages, including when Evenda is closed. Evenda Now requests
 * arrive as data-only, high-priority messages (kind = now_request) so Android
 * wakes this service and Evenda builds the call-style alert itself; the system
 * would otherwise show a plain notification. Everything else goes to the
 * firebase_messaging plugin as before.
 */
class EvendaMessagingService : FlutterFirebaseMessagingService() {
    override fun onMessageReceived(remoteMessage: RemoteMessage) {
        super.onMessageReceived(remoteMessage)
        val data = remoteMessage.data
        // With Evenda on screen, the app shows its own incoming screen.
        if (data["kind"] == "now_request" && !MainActivity.visible) IncomingAlert.show(applicationContext, data)
    }
}
