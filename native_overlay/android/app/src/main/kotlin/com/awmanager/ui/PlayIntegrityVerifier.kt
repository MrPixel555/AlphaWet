package com.awmanager.ui

import android.content.Context
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.IntegrityTokenRequest
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

object PlayIntegrityVerifier {
    private const val timeoutMs = 8_000L

    // Set this in app/build.gradle(.kts) buildConfigField("long", "PLAY_CLOUD_PROJECT_NUMBER", "123...")
    private const val defaultCloudProjectNumber = 0L

    fun requireStrongIntegrity(context: Context) {
        val cloudProjectNumber = resolveCloudProjectNumber(context)
        if (cloudProjectNumber <= 0L) {
            throw SecurityException("Play Integrity is not configured (missing cloud project number).")
        }

        val manager = IntegrityManagerFactory.create(context)
        val nonce = sha256(UUID.randomUUID().toString())
        val request = IntegrityTokenRequest.builder()
            .setNonce(nonce)
            .setCloudProjectNumber(cloudProjectNumber)
            .build()

        val tokenRef = AtomicReference<String?>(null)
        val errorRef = AtomicReference<Exception?>(null)
        val latch = CountDownLatch(1)

        manager.requestIntegrityToken(request)
            .addOnSuccessListener { response ->
                tokenRef.set(response.token())
                latch.countDown()
            }
            .addOnFailureListener { error ->
                errorRef.set(Exception(error))
                latch.countDown()
            }

        if (!latch.await(timeoutMs, TimeUnit.MILLISECONDS)) {
            throw SecurityException("Play Integrity check timed out.")
        }
        errorRef.get()?.let {
            throw SecurityException("Play Integrity check failed: ${it.message}")
        }

        // Client side can only ensure token issuance. The final strong verdict must be validated server-side.
        val token = tokenRef.get().orEmpty().trim()
        if (token.isEmpty()) {
            throw SecurityException("Play Integrity returned an empty token.")
        }
    }

    private fun resolveCloudProjectNumber(context: Context): Long {
        return runCatching {
            val field = Class.forName("${context.packageName}.BuildConfig").getDeclaredField("PLAY_CLOUD_PROJECT_NUMBER")
            field.getLong(null)
        }.getOrElse { defaultCloudProjectNumber }
    }

    private fun sha256(value: String): String {
        val bytes = MessageDigest.getInstance("SHA-256").digest(value.toByteArray())
        return bytes.joinToString("") { "%02x".format(it) }
    }
}
