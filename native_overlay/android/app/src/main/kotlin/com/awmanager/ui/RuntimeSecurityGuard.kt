package com.awmanager.ui

import android.content.Context
import android.os.Build
import android.os.Debug
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket

object RuntimeSecurityGuard {
    private val suCandidates = listOf(
        "/system/bin/su",
        "/system/xbin/su",
        "/sbin/su",
        "/su/bin/su",
        "/system/app/Superuser.apk",
        "/system/bin/.ext/.su",
        "/system/usr/we-need-root/su",
        "/system/sd/xbin/su",
        "/data/local/xbin/su",
        "/data/local/bin/su",
        "/data/local/su",
        "/magisk/.core/bin/su",
    )

    fun enforceRuntimeSecurity(context: Context) {
        val issues = mutableListOf<String>()
        if (isRooted()) {
            issues += "ROOT_DETECTED"
        }
        if (isFridaDetected()) {
            issues += "FRIDA_DETECTED"
        }
        if (Debug.isDebuggerConnected() || Debug.waitingForDebugger()) {
            issues += "DEBUGGER_DETECTED"
        }
        if (issues.isNotEmpty()) {
            throw SecurityException("Runtime security policy violation: ${issues.joinToString(",")}")
        }
    }

    fun isRooted(): Boolean {
        if (Build.TAGS?.contains("test-keys") == true) return true

        if (suCandidates.any { File(it).exists() }) return true

        val suCheck = runCatching {
            val process = ProcessBuilder("which", "su").redirectErrorStream(true).start()
            val output = process.inputStream.bufferedReader().use { it.readText().trim() }
            process.waitFor()
            output.isNotBlank()
        }.getOrDefault(false)
        if (suCheck) return true

        val rwPaths = listOf("/system", "/system/bin", "/system/xbin", "/vendor/bin")
        val mountOutput = runCatching {
            ProcessBuilder("mount").redirectErrorStream(true).start()
                .inputStream.bufferedReader().use { it.readText() }
        }.getOrDefault("")
        if (mountOutput.isNotBlank()) {
            val lowered = mountOutput.lowercase()
            if (rwPaths.any { path -> lowered.contains(" $path ") && lowered.contains(" rw,") }) {
                return true
            }
        }

        return false
    }

    private fun isFridaDetected(): Boolean {
        val suspiciousPorts = listOf(27042, 27043, 23946)
        if (suspiciousPorts.any { isPortOpen(it) }) return true

        val ps = runCatching {
            ProcessBuilder("ps", "-A").redirectErrorStream(true).start()
                .inputStream.bufferedReader().use { it.readText() }
        }.getOrDefault("").lowercase()
        if (ps.contains("frida") || ps.contains("gum-js-loop") || ps.contains("gadget")) return true

        val maps = runCatching { File("/proc/self/maps").readText().lowercase() }.getOrDefault("")
        if (maps.contains("frida") || maps.contains("gadget") || maps.contains("libfrida")) return true

        return false
    }

    private fun isPortOpen(port: Int): Boolean {
        return runCatching {
            Socket().use { socket ->
                socket.connect(InetSocketAddress("127.0.0.1", port), 120)
                true
            }
        }.getOrDefault(false)
    }
}
