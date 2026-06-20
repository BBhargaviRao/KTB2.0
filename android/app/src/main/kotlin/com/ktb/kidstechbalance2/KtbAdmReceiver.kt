package com.ktb.kidstechbalance2.adm

import com.amazon.device.messaging.ADMMessageReceiver

class KtbAdmReceiver : ADMMessageReceiver(KtbAdmLegacyMessageHandler::class.java) {
    init {
        registerJobServiceClass(KtbAdmMessageHandler::class.java, 1001)
    }
}