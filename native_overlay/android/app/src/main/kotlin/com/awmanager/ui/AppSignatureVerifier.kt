package com.awmanager.ui

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import java.security.MessageDigest
import java.util.Locale

object AppSignatureVerifier {
    fun isSignatureValid(context: Context): Boolean {
        val expected = BuildConfig.EXPECTED_SIGNING_CERT_SHA256.trim().uppercase(Locale.US)
        if (expected.isBlank()) return true
        val actual = currentSha256(context) ?: return false
        return actual == expected
    }

    fun diagnosticReport(context: Context): String {
        val expected = BuildConfig.EXPECTED_SIGNING_CERT_SHA256.trim().uppercase(Locale.US)
        val actual = currentSha256(context)
        return buildString {
            appendLine("Signature check")
            appendLine("expectedSha256=${expected.ifBlank { "<blank>" }}")
            appendLine("actualSha256=${actual ?: "<unavailable>"}")
            appendLine("match=${if (expected.isBlank()) "skipped" else (actual == expected)}")
        }.trim()
    }

    private fun currentSha256(context: Context): String? {
        val pm = context.packageManager
        val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            pm.getPackageInfo(context.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageInfo(context.packageName, PackageManager.GET_SIGNATURES)
        }
        val bytes = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val info = packageInfo.signingInfo ?: return null
            val sig = if (info.hasMultipleSigners()) info.apkContentsSigners.firstOrNull() else info.signingCertificateHistory.firstOrNull()
            sig?.toByteArray()
        } else {
            @Suppress("DEPRECATION")
            packageInfo.signatures?.firstOrNull()?.toByteArray()
        } ?: return null
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return digest.joinToString("") { "%02X".format(it) }
    }
}
