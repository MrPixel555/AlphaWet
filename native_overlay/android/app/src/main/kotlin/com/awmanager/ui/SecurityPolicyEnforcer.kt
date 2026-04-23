package com.awmanager.ui

import android.content.Context
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.IntegrityTokenRequest
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Base64

class SecurityPolicyEnforcer(private val context: Context) {
    fun enforceStartupPolicy() {
        if (SecurityLockStore.isLocked(context)) {
            throw SecurityException(SecurityLockStore.reason(context))
        }
        if (RuntimeSecurityGuard.isRooted()) {
            SecurityLockStore.markLocked(context, "ROOT_DETECTED")
            throw SecurityException("ROOT_DETECTED")
        }
        if (!AppSignatureVerifier.isSignatureValid(context)) {
            SecurityLockStore.markLocked(context, "SIGNATURE_MISMATCH")
            throw SecurityException("SIGNATURE_MISMATCH")
        }
        RuntimeSecurityGuard.enforceRuntimeSecurity(context)
    }

    fun performPostConnectPolicy(configId: String): Map<String, Any?> {
        enforceStartupPolicy()
        val cloudProjectNumber = BuildConfig.PLAY_CLOUD_PROJECT_NUMBER
        if (cloudProjectNumber <= 0L) {
            return mapOf(
                "success" to true,
                "state" to "connected",
                "message" to "Connected. Play Integrity cloud project number is not configured, so local policy checks passed.",
            )
        }
        val nonceDigest = MessageDigest.getInstance("SHA-256")
            .digest((context.packageName + ":" + configId + ":" + System.currentTimeMillis()).toByteArray(StandardCharsets.UTF_8))
        val nonce = Base64.getUrlEncoder().withoutPadding().encodeToString(nonceDigest)
        val manager = IntegrityManagerFactory.create(context)
        val response = try {
            com.google.android.gms.tasks.Tasks.await(
                manager.requestIntegrityToken(
                    IntegrityTokenRequest.builder()
                        .setCloudProjectNumber(cloudProjectNumber)
                        .setNonce(nonce)
                        .build(),
                ),
            )
        } catch (error: Throwable) {
            SecurityLockStore.markLocked(context, "INTEGRITY_REQUEST_FAILED")
            throw SecurityException("INTEGRITY_REQUEST_FAILED")
        }
        val token = response.token()
        if (token.isNullOrBlank()) {
            SecurityLockStore.markLocked(context, "INTEGRITY_TOKEN_EMPTY")
            throw SecurityException("INTEGRITY_TOKEN_EMPTY")
        }
        return mapOf(
            "success" to true,
            "state" to "connected",
            "message" to "Connected. Post-connect integrity check passed.",
            "integrityTokenLength" to token.length,
        )
    }
}
