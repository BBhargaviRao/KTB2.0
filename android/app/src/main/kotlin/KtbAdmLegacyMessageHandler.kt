package com.example.ktb_nudges.adm

import android.content.Intent
import android.os.Bundle
import android.util.Log
import com.amazon.device.messaging.ADMMessageHandlerBase

class KtbAdmLegacyMessageHandler : ADMMessageHandlerBase("KtbAdmLegacyMessageHandler") {

    override fun onRegistered(registrationId: String) {
        Log.d("ADM", "Legacy ADM registered: $registrationId")
    }

    override fun onUnregistered(registrationId: String) {
        Log.d("ADM", "Legacy ADM unregistered: $registrationId")
    }

    override fun onRegistrationError(errorId: String) {
        Log.e("ADM", "Legacy ADM registration error: $errorId")
    }

    override fun onMessage(intent: Intent) {
        val extras: Bundle? = intent.extras
        Log.d("ADM", "Legacy ADM message received. Extras: $extras")
    }
}