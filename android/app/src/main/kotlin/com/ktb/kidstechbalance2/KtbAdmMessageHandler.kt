package com.ktb.kidstechbalance2.adm

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.core.app.NotificationCompat
import com.amazon.device.messaging.ADMMessageHandlerJobBase
import com.ktb.kidstechbalance2.MainActivity
import com.ktb.kidstechbalance2.R

class KtbAdmMessageHandler : ADMMessageHandlerJobBase() {

    override fun onRegistered(context: Context, registrationId: String) {
        Log.d("ADM", "Registered with ADM: $registrationId")

        val prefs = context.getSharedPreferences("ktb_adm_prefs", Context.MODE_PRIVATE)
        prefs.edit().putString("adm_registration_id", registrationId).apply()
    }

    override fun onUnregistered(context: Context, registrationId: String) {
        Log.d("ADM", "Unregistered from ADM: $registrationId")
    }

    override fun onRegistrationError(context: Context, errorId: String) {
        Log.e("ADM", "ADM registration error: $errorId")
    }

    override fun onMessage(context: Context, intent: Intent) {
        val extras: Bundle? = intent.extras
        Log.d("ADM", "ADM message received. Extras: $extras")

        val title = extras?.getString("title") ?: "New nudge"
        val body = extras?.getString("body") ?: "Tap to open your app"

        val channelId = "ktb2_channel"
        val notificationManager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "KTB Nudges",
                NotificationManager.IMPORTANCE_HIGH
            )
            notificationManager.createNotificationChannel(channel)
        }

        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }

        val pendingIntent = PendingIntent.getActivity(
            context,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()

        notificationManager.notify(1001, notification)
    }
}