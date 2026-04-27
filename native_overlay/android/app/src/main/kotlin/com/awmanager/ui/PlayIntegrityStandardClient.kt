package com.awmanager.ui

import android.content.Context
import com.google.android.gms.tasks.Tasks
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.StandardIntegrityManager
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import java.util.concurrent.TimeUnit

internal data class IntegrityCheckRequestData(
    val packageName: String,
    val configId: String,
    val issuedAtMillis: Long,
    val requestHash: String,
)

internal object IntegrityCheckRequestFactory {
    fun create(context: Context, configId: String): IntegrityCheckRequestData {
        val issuedAtMillis = System.currentTimeMillis()
        val canonical = listOf(
            context.packageName,
            configId,
            issuedAtMillis.toString(),
            UUID.randomUUID().toString(),
        ).joinToString("|")
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(canonical.toByteArray(StandardCharsets.UTF_8))
        val requestHash = Base64.getUrlEncoder().withoutPadding().encodeToString(digest)
        return IntegrityCheckRequestData(
            packageName = context.packageName,
            configId = configId,
            issuedAtMillis = issuedAtMillis,
            requestHash = requestHash,
        )
    }
}

object PlayIntegrityStandardClient {
    private const val prepareTimeoutSeconds = 15L
    private const val requestTimeoutSeconds = 8L

    @Volatile
    private var tokenProvider: StandardIntegrityManager.StandardIntegrityTokenProvider? = null

    private val providerLock = Any()

    fun warmUp(context: Context, cloudProjectNumber: Long) {
        if (cloudProjectNumber <= 0L) {
            throw SecurityException("Play Integrity is not configured (missing cloud project number).")
        }
        ensureProvider(context, cloudProjectNumber, forceRefresh = false)
    }

    fun requestToken(
        context: Context,
        cloudProjectNumber: Long,
        requestHash: String,
    ): String {
        val startedAt = System.currentTimeMillis()
        return runCatching {
            val provider = ensureProvider(context, cloudProjectNumber, forceRefresh = false)
            requestToken(provider, requestHash)
        }.recoverCatching {
            val provider = ensureProvider(context, cloudProjectNumber, forceRefresh = true)
            requestToken(provider, requestHash)
        }.getOrElse { error ->
            val elapsed = System.currentTimeMillis() - startedAt
            throw SecurityException(
                "Play Integrity token request failed after ${elapsed} ms: ${error.message}",
            )
        }
    }

    private fun ensureProvider(
        context: Context,
        cloudProjectNumber: Long,
        forceRefresh: Boolean,
    ): StandardIntegrityManager.StandardIntegrityTokenProvider {
        if (!forceRefresh) {
            tokenProvider?.let { return it }
        }
        synchronized(providerLock) {
            if (!forceRefresh) {
                tokenProvider?.let { return it }
            }
            val manager = IntegrityManagerFactory.createStandard(context)
            val request = StandardIntegrityManager.PrepareIntegrityTokenRequest.builder()
                .setCloudProjectNumber(cloudProjectNumber)
                .build()
            val prepareStartedAt = System.currentTimeMillis()
            val provider = try {
                Tasks.await(
                    manager.prepareIntegrityToken(request),
                    prepareTimeoutSeconds,
                    TimeUnit.SECONDS,
                )
            } catch (error: Throwable) {
                val elapsed = System.currentTimeMillis() - prepareStartedAt
                throw SecurityException(
                    "Play Integrity provider preparation failed after ${elapsed} ms "
                        + "(forceRefresh=$forceRefresh, cloudProjectNumber=$cloudProjectNumber): "
                        + "${error.message ?: error.javaClass.simpleName}",
                )
            }
            tokenProvider = provider
            return provider
        }
    }

    private fun requestToken(
        provider: StandardIntegrityManager.StandardIntegrityTokenProvider,
        requestHash: String,
    ): String {
        val request = StandardIntegrityManager.StandardIntegrityTokenRequest.builder()
            .setRequestHash(requestHash)
            .build()
        val requestStartedAt = System.currentTimeMillis()
        val response = try {
            Tasks.await(
                provider.request(request),
                requestTimeoutSeconds,
                TimeUnit.SECONDS,
            )
        } catch (error: Throwable) {
            val elapsed = System.currentTimeMillis() - requestStartedAt
            throw SecurityException(
                "Play Integrity token provider.request failed after ${elapsed} ms "
                    + "(requestHashPrefix=${requestHash.take(12)}): "
                    + "${error.message ?: error.javaClass.simpleName}",
            )
        }
        val token = response.token().orEmpty().trim()
        if (token.isEmpty()) {
            throw SecurityException("Play Integrity returned an empty token.")
        }
        return token
    }
}
