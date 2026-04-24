package com.awmanager.ui

import android.content.Context

class SecurityPolicyEnforcer(private val context: Context) {
    companion object {
        private const val requiredDeviceIntegrityLabel = "MEETS_DEVICE_INTEGRITY"
        private const val maxVerdictAgeMillis = 2 * 60 * 1000L
    }

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

    fun warmUpIntegrityProviderIfConfigured() {
        val cloudProjectNumber = BuildConfig.PLAY_CLOUD_PROJECT_NUMBER
        if (cloudProjectNumber <= 0L) {
            return
        }
        PlayIntegrityStandardClient.warmUp(context, cloudProjectNumber)
    }

    fun performPostConnectPolicy(configId: String): Map<String, Any?> {
        enforceStartupPolicy()

        val cloudProjectNumber = BuildConfig.PLAY_CLOUD_PROJECT_NUMBER
        if (cloudProjectNumber <= 0L) {
            SecurityLockStore.markLocked(context, "PLAY_CLOUD_PROJECT_NUMBER_MISSING")
            throw SecurityException("PLAY_CLOUD_PROJECT_NUMBER_MISSING")
        }

        val verdictUrl = BuildConfig.PLAY_INTEGRITY_VERDICT_URL.trim()
        if (verdictUrl.isBlank()) {
            SecurityLockStore.markLocked(context, "INTEGRITY_VERDICT_ENDPOINT_MISSING")
            throw SecurityException("INTEGRITY_VERDICT_ENDPOINT_MISSING")
        }

        val requestData = IntegrityCheckRequestFactory.create(context, configId)
        val integrityToken = try {
            PlayIntegrityStandardClient.requestToken(
                context = context,
                cloudProjectNumber = cloudProjectNumber,
                requestHash = requestData.requestHash,
            )
        } catch (error: Throwable) {
            SecurityLockStore.markLocked(context, "INTEGRITY_TOKEN_REQUEST_FAILED")
            throw SecurityException("INTEGRITY_TOKEN_REQUEST_FAILED")
        }

        val decoded = try {
            IntegrityVerdictHttpClient.decodeAndValidate(
                verdictUrl = verdictUrl,
                requestData = requestData,
                integrityToken = integrityToken,
                requiredLabel = requiredDeviceIntegrityLabel,
            )
        } catch (error: Throwable) {
            SecurityLockStore.markLocked(context, "INTEGRITY_VERDICT_DECODE_FAILED")
            throw SecurityException("INTEGRITY_VERDICT_DECODE_FAILED")
        }

        if (decoded.requestPackageName != context.packageName) {
            SecurityLockStore.markLocked(context, "INTEGRITY_PACKAGE_NAME_MISMATCH")
            throw SecurityException("INTEGRITY_PACKAGE_NAME_MISMATCH")
        }
        if (!decoded.allowed) {
            SecurityLockStore.markLocked(context, "INTEGRITY_BACKEND_POLICY_REJECTED")
            throw SecurityException("INTEGRITY_BACKEND_POLICY_REJECTED")
        }
        if (decoded.requestHash != requestData.requestHash) {
            SecurityLockStore.markLocked(context, "INTEGRITY_REQUEST_HASH_MISMATCH")
            throw SecurityException("INTEGRITY_REQUEST_HASH_MISMATCH")
        }
        val now = System.currentTimeMillis()
        if (decoded.requestTimestampMillis <= 0L || now - decoded.requestTimestampMillis > maxVerdictAgeMillis) {
            SecurityLockStore.markLocked(context, "INTEGRITY_TOKEN_STALE")
            throw SecurityException("INTEGRITY_TOKEN_STALE")
        }
        if (!decoded.appRecognitionVerdict.contains("PLAY_RECOGNIZED")) {
            SecurityLockStore.markLocked(context, "APP_INTEGRITY_NOT_RECOGNIZED")
            throw SecurityException("APP_INTEGRITY_NOT_RECOGNIZED")
        }
        if (!decoded.meetsDeviceIntegrity) {
            val reason = if (decoded.deviceRecognitionVerdict.isEmpty()) {
                "DEVICE_INTEGRITY_BELOW_MEETS_DEVICE_INTEGRITY"
            } else {
                "DEVICE_INTEGRITY_BELOW_MEETS_DEVICE_INTEGRITY:${decoded.deviceRecognitionVerdict.joinToString("|")}"
            }
            SecurityLockStore.markLocked(context, reason)
            throw SecurityException(reason)
        }

        return mapOf(
            "success" to true,
            "state" to "connected",
            "message" to "Connected. Post-connect integrity verdict passed.",
            "requiredDeviceIntegrityLabel" to requiredDeviceIntegrityLabel,
            "deviceRecognitionVerdict" to decoded.deviceRecognitionVerdict.toList(),
            "appRecognitionVerdict" to decoded.appRecognitionVerdict.toList(),
            "certificateSha256Digest" to decoded.certificateDigests.toList(),
            "requestTimestampMillis" to decoded.requestTimestampMillis,
        )
    }
}
