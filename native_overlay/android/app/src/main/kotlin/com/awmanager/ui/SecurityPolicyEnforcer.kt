package com.awmanager.ui

import android.content.Context

class SecurityPolicyEnforcer(private val context: Context) {
    companion object {
        private const val requiredDeviceIntegrityLabel = "MEETS_DEVICE_INTEGRITY"
        private const val maxVerdictAgeMillis = 2 * 60 * 1000L
        private val recoverableLockReasons = setOf(
            "PLAY_CLOUD_PROJECT_NUMBER_MISSING",
            "INTEGRITY_VERDICT_ENDPOINT_MISSING",
            "INTEGRITY_TOKEN_REQUEST_FAILED",
            "INTEGRITY_REQUEST_HASH_MISMATCH",
            "INTEGRITY_TOKEN_STALE",
        )
    }

    fun enforceStartupPolicy() {
        if (SecurityLockStore.isLocked(context)) {
            val reason = SecurityLockStore.reason(context)
            if (reason in recoverableLockReasons) {
                SecurityLockStore.clear(context)
            } else {
                throw SecurityException(reason)
            }
        }
        if (RuntimeSecurityGuard.isRooted()) {
            throw SecurityException(
                buildString {
                    appendLine("ROOT_DETECTED")
                    RuntimeSecurityGuard.collectFindings().forEach { appendLine(it) }
                }.trim(),
            )
        }
        if (!AppSignatureVerifier.isSignatureValid(context)) {
            throw SecurityException(
                buildString {
                    appendLine("SIGNATURE_MISMATCH")
                    append(AppSignatureVerifier.diagnosticReport(context))
                },
            )
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

    fun performPostConnectPolicy(
        configId: String,
        enableDeviceVpn: Boolean,
        httpPort: Int,
    ): Map<String, Any?> {
        val startedAt = System.currentTimeMillis()
        enforceStartupPolicy()

        val cloudProjectNumber = BuildConfig.PLAY_CLOUD_PROJECT_NUMBER
        if (cloudProjectNumber <= 0L) {
            throw SecurityException("PLAY_CLOUD_PROJECT_NUMBER_MISSING")
        }

        val verdictUrl = BuildConfig.PLAY_INTEGRITY_VERDICT_URL.trim()
        if (verdictUrl.isBlank()) {
            throw SecurityException("INTEGRITY_VERDICT_ENDPOINT_MISSING")
        }

        val requestData = IntegrityCheckRequestFactory.create(context, configId)
        val tokenStartedAt = System.currentTimeMillis()
        val integrityToken = try {
            PlayIntegrityStandardClient.requestToken(
                context = context,
                cloudProjectNumber = cloudProjectNumber,
                requestHash = requestData.requestHash,
            )
        } catch (error: Throwable) {
            val elapsed = System.currentTimeMillis() - tokenStartedAt
            throw SecurityException(
                "INTEGRITY_TOKEN_REQUEST_FAILED: elapsedMs=$elapsed, "
                    + "configId=$configId, cloudProjectNumber=$cloudProjectNumber, "
                    + "requestHashPrefix=${requestData.requestHash.take(12)}, "
                    + "message=${error.message ?: error.javaClass.simpleName}",
            )
        }

        val verdictStartedAt = System.currentTimeMillis()
        val decoded = try {
            IntegrityVerdictHttpClient.decodeAndValidate(
                verdictUrl = verdictUrl,
                requestData = requestData,
                integrityToken = integrityToken,
                requiredLabel = requiredDeviceIntegrityLabel,
                useActiveTunnelProxy = !enableDeviceVpn,
                proxyHttpPort = httpPort,
            )
        } catch (error: Throwable) {
            val elapsed = System.currentTimeMillis() - verdictStartedAt
            throw SecurityException(
                "INTEGRITY_VERDICT_DECODE_FAILED: elapsedMs=$elapsed, "
                    + "configId=$configId, verdictUrl=$verdictUrl, "
                    + "viaProxy=${!enableDeviceVpn}, proxyHttpPort=$httpPort, "
                    + "requestHashPrefix=${requestData.requestHash.take(12)}, "
                    + "message=${error.message ?: "UNREACHABLE"}",
            )
        }

        if (decoded.requestPackageName != context.packageName) {
            SecurityLockStore.markLocked(context, "INTEGRITY_PACKAGE_NAME_MISMATCH")
            throw SecurityException(
                "INTEGRITY_PACKAGE_NAME_MISMATCH: expected=${context.packageName}, actual=${decoded.requestPackageName}",
            )
        }
        if (!decoded.allowed) {
            SecurityLockStore.markLocked(context, "INTEGRITY_BACKEND_POLICY_REJECTED")
            throw SecurityException(
                buildString {
                    appendLine("INTEGRITY_BACKEND_POLICY_REJECTED")
                    appendLine("deviceRecognitionVerdict=${decoded.deviceRecognitionVerdict.joinToString("|")}")
                    appendLine("appRecognitionVerdict=${decoded.appRecognitionVerdict.joinToString("|")}")
                    appendLine("certificateSha256Digest=${decoded.certificateDigests.joinToString("|")}")
                    append("rawPayload=${decoded.rawPayload}")
                },
            )
        }
        if (decoded.requestHash != requestData.requestHash) {
            throw SecurityException(
                "INTEGRITY_REQUEST_HASH_MISMATCH: expected=${requestData.requestHash}, actual=${decoded.requestHash}",
            )
        }
        val now = System.currentTimeMillis()
        if (decoded.requestTimestampMillis <= 0L || now - decoded.requestTimestampMillis > maxVerdictAgeMillis) {
            throw SecurityException(
                "INTEGRITY_TOKEN_STALE: now=$now, verdictTs=${decoded.requestTimestampMillis}, ageMs=${now - decoded.requestTimestampMillis}",
            )
        }
        if (!decoded.appRecognitionVerdict.contains("PLAY_RECOGNIZED")) {
            SecurityLockStore.markLocked(context, "APP_INTEGRITY_NOT_RECOGNIZED")
            throw SecurityException(
                "APP_INTEGRITY_NOT_RECOGNIZED: ${decoded.appRecognitionVerdict.joinToString("|")}",
            )
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
            "message" to "Connected. Post-connect integrity verdict passed. totalElapsedMs=${System.currentTimeMillis() - startedAt}",
            "requiredDeviceIntegrityLabel" to requiredDeviceIntegrityLabel,
            "deviceRecognitionVerdict" to decoded.deviceRecognitionVerdict.toList(),
            "appRecognitionVerdict" to decoded.appRecognitionVerdict.toList(),
            "certificateSha256Digest" to decoded.certificateDigests.toList(),
            "requestTimestampMillis" to decoded.requestTimestampMillis,
            "requestHashPrefix" to requestData.requestHash.take(12),
        )
    }
}
