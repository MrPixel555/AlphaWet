package com.awmanager.ui

import android.content.Context
import io.flutter.plugin.common.MethodCall
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.Socket
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

class XrayCoreRuntimeBridge(private val context: Context) {
    companion object {
        const val CHANNEL = "alphawet/xray_core"
    }

    fun validateConfig(call: MethodCall): Map<String, Any?> {
        val bundle = prepareBundle(call)
        return XrayCoreRuntimeManager.validate(bundle)
    }

    fun startCore(call: MethodCall): Map<String, Any?> {
        val bundle = prepareBundle(call)
        return if (bundle.enableDeviceVpn) {
            AlphaWetVpnService.requestStart(context, bundle)
        } else {
            XrayCoreRuntimeManager.start(bundle)
        }
    }

    fun stopCore(call: MethodCall): Map<String, Any?> {
        val configId = call.argument<String>("configId") ?: "unknown"
        return if (XrayCoreRuntimeManager.isDeviceVpnMode()) {
            AlphaWetVpnService.requestStop(context, configId)
        } else {
            XrayCoreRuntimeManager.stop(configId)
        }
    }

    fun pingProxy(call: MethodCall): Map<String, Any?> {
        val httpPort = call.argument<Int>("httpPort") ?: 10808
        val url = call.argument<String>("url")?.trim().takeUnless { it.isNullOrEmpty() }
            ?: "https://www.google.com/generate_204"
        val configJson = call.argument<String>("configJson")?.trim().takeUnless { it.isNullOrEmpty() }
        val configId = call.argument<String>("configId")?.trim().takeUnless { it.isNullOrEmpty() }
            ?: "ping"
        val displayName = call.argument<String>("displayName")?.trim().takeUnless { it.isNullOrEmpty() }
            ?: configId
        val targetHost = call.argument<String>("targetHost")?.trim().takeUnless { it.isNullOrEmpty() }
        val targetPort = call.argument<Int>("targetPort")
        val socksPort = call.argument<Int>("socksPort") ?: 10809

        if (XrayCoreRuntimeManager.isActiveProxyPort(httpPort)) {
            return XrayCoreRuntimeManager.pingProxy(httpPort = httpPort, url = url)
        }

        val packagedBinary = resolvePackagedBinaryOrNull()
        if (configJson != null && packagedBinary != null) {
            val bundle = prepareBundleFromRaw(
                configId = "ping_$configId",
                displayName = "$displayName (Ping)",
                configJson = configJson,
                httpPort = httpPort,
                socksPort = socksPort,
                enableDeviceVpn = false,
                binaryFile = packagedBinary,
            )
            return XrayCoreRuntimeManager.pingViaTransientRuntime(bundle = bundle, url = url)
        }

        if (targetHost != null && targetPort != null) {
            val fallbackReason = if (packagedBinary == null) {
                "Packaged runtime was not found, so a direct TCP reachability probe was used instead of a proxy test."
            } else {
                "A generated runtime config was unavailable, so a direct TCP reachability probe was used instead of a proxy test."
            }
            return XrayCoreRuntimeManager.pingTargetDirect(
                host = targetHost,
                port = targetPort,
                reason = fallbackReason,
            )
        }

        return mapOf(
            "success" to false,
            "message" to when {
                packagedBinary == null ->
                    "Packaged runtime was not found and no direct host/port fallback was available for ping."
                else ->
                    "Ping requires either a running runtime, a ready generated config, or a host/port target."
            },
        )
    }

    fun getCoreStatus(): Map<String, Any?> = XrayCoreRuntimeManager.status()

    private fun prepareBundle(call: MethodCall): RuntimeBundle {
        val configId = requireNotNull(call.argument<String>("configId")) { "configId is required." }
        val displayName = (call.argument<String>("displayName") ?: configId).trim()
        val configJson = requireNotNull(call.argument<String>("configJson")) { "configJson is required." }
        val httpPort = call.argument<Int>("httpPort") ?: 10808
        val socksPort = call.argument<Int>("socksPort") ?: 10809
        val enableDeviceVpn = call.argument<Boolean>("enableDeviceVpn") == true
        val binaryFile = resolvePackagedBinary()
        return prepareBundleFromRaw(
            configId = configId,
            displayName = displayName,
            configJson = configJson,
            httpPort = httpPort,
            socksPort = socksPort,
            enableDeviceVpn = enableDeviceVpn,
            binaryFile = binaryFile,
        )
    }

    private fun prepareBundleFromRaw(
        configId: String,
        displayName: String,
        configJson: String,
        httpPort: Int,
        socksPort: Int,
        enableDeviceVpn: Boolean,
        binaryFile: File,
    ): RuntimeBundle {
        val runtimeRoot = File(context.filesDir, "xray_runtime").apply { mkdirs() }
        val configRoot = File(runtimeRoot, "configs").apply { mkdirs() }
        val assetsRoot = File(runtimeRoot, "assets").apply { mkdirs() }
        val workRoot = File(runtimeRoot, "work").apply { mkdirs() }
        val logRoot = File(runtimeRoot, "logs").apply { mkdirs() }

        val configFile = File(configRoot, "$configId.json")
        configFile.writeText(configJson)

        copyOptionalCommonAsset("geoip.dat", assetsRoot)
        copyOptionalCommonAsset("geosite.dat", assetsRoot)

        val logFileName = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date()) + "_$configId.log"
        val logFile = File(logRoot, logFileName)

        return RuntimeBundle(
            configId = configId,
            displayName = displayName,
            configFile = configFile,
            binaryFile = binaryFile,
            assetDir = assetsRoot,
            workDir = workRoot,
            logFile = logFile,
            httpPort = httpPort,
            socksPort = socksPort,
            enableDeviceVpn = enableDeviceVpn,
        )
    }

    private fun resolvePackagedBinary(): File {
        return resolvePackagedBinaryOrNull()
            ?: throw IllegalStateException(buildMissingRuntimeMessage())
    }

    private fun resolvePackagedBinaryOrNull(): File? {
        val nativeLibraryDir = context.applicationInfo.nativeLibraryDir?.trim().orEmpty()
        val candidates = mutableListOf<File>()
        if (nativeLibraryDir.isNotEmpty()) {
            val nativeDir = File(nativeLibraryDir)
            val parent = nativeDir.parentFile
            candidates += File(nativeDir, "libxraycore.so")
            candidates += File(nativeDir, "xray")
            if (parent != null && parent.exists()) {
                val abiDirNames = sequenceOf(nativeDir.name) + android.os.Build.SUPPORTED_ABIS.asSequence()
                abiDirNames.distinct().forEach { abi ->
                    candidates += File(parent, "$abi/libxraycore.so")
                    candidates += File(parent, "$abi/xray")
                }
            }
        }

        val winner = candidates.firstOrNull { it.isFile }
        if (winner != null) {
            winner.setReadable(true, false)
            winner.setExecutable(true, false)
            return winner
        }
        return null
    }

    private fun buildMissingRuntimeMessage(): String {
        val nativeLibraryDir = context.applicationInfo.nativeLibraryDir ?: "unavailable"
        val listing = runCatching {
            File(nativeLibraryDir).list()?.sorted()?.joinToString(", ")
        }.getOrNull().takeUnless { it.isNullOrBlank() } ?: "(empty or inaccessible)"
        return "Packaged runtime was not found in nativeLibraryDir ($nativeLibraryDir). Directory listing: $listing. " +
            "Ensure tool/prepare_android_runtime.sh copied assets/xray/android/arm64-v8a/xray to " +
            "android/app/src/main/jniLibs/arm64-v8a/libxraycore.so before building."
    }

    private fun copyOptionalCommonAsset(fileName: String, assetsRoot: File) {
        val assetPath = "flutter_assets/assets/xray/common/$fileName"
        if (!assetExists(assetPath)) {
            return
        }
        val target = File(assetsRoot, fileName)
        context.assets.open(assetPath).use { input ->
            FileOutputStream(target).use { output -> input.copyTo(output) }
        }
        target.setReadable(true, true)
        target.setWritable(true, true)
    }

    private fun assetExists(assetPath: String): Boolean {
        return try {
            context.assets.open(assetPath).close()
            true
        } catch (_: Exception) {
            false
        }
    }
}

data class RuntimeBundle(
    val configId: String,
    val displayName: String,
    val configFile: File,
    val binaryFile: File,
    val assetDir: File,
    val workDir: File,
    val logFile: File,
    val httpPort: Int,
    val socksPort: Int,
    val enableDeviceVpn: Boolean,
)

object XrayCoreRuntimeManager {
    private val lock = Any()
    private var sessionId: String? = null
    private var activeConfigId: String? = null
    private var activePid: Long? = null
    private var lastMessage: String = "Idle."
    private var lastLogFile: File? = null
    private var currentHttpPort: Int = 10808
    private var currentSocksPort: Int = 10809
    private var currentDeviceVpnMode: Boolean = false
    private var lastBundle: RuntimeBundle? = null
    private var currentTunFd: Int = -1

    fun validate(bundle: RuntimeBundle): Map<String, Any?> {
        val exitCode = XrayNativeBridge.validate(
            bundle.binaryFile.absolutePath,
            bundle.configFile.absolutePath,
            bundle.assetDir.absolutePath,
            bundle.workDir.absolutePath,
            bundle.logFile.absolutePath,
        )
        val outputTail = tailLog(bundle.logFile)
        return if (exitCode == 0) {
            mapOf(
                "state" to "ready",
                "success" to true,
                "message" to buildReadyMessage(bundle),
                "configId" to bundle.configId,
                "displayName" to bundle.displayName,
                "httpPort" to bundle.httpPort,
                "socksPort" to bundle.socksPort,
                "deviceVpnMode" to bundle.enableDeviceVpn,
                "logFilePath" to bundle.logFile.absolutePath,
                "outputTail" to outputTail,
            )
        } else {
            mapOf(
                "state" to "error",
                "success" to false,
                "message" to buildString {
                    append("Runtime validation failed with exit code ")
                    append(exitCode)
                    append('.')
                    if (outputTail.isNotBlank()) {
                        append("\n")
                        append(outputTail)
                    }
                },
                "configId" to bundle.configId,
                "displayName" to bundle.displayName,
                "httpPort" to bundle.httpPort,
                "socksPort" to bundle.socksPort,
                "deviceVpnMode" to bundle.enableDeviceVpn,
                "logFilePath" to bundle.logFile.absolutePath,
                "outputTail" to outputTail,
            )
        }
    }

    fun start(bundle: RuntimeBundle, tunFd: Int = -1): Map<String, Any?> = synchronized(lock) {
        val runningPid = activePid
        if (runningPid != null && XrayNativeBridge.isRunning(runningPid)) {
            return@synchronized mapOf(
                "state" to "running",
                "success" to true,
                "message" to "Runtime is already running.",
                "configId" to activeConfigId,
                "sessionId" to sessionId,
                "httpPort" to currentHttpPort,
                "socksPort" to currentSocksPort,
                "deviceVpnMode" to currentDeviceVpnMode,
                "logFilePath" to lastLogFile?.absolutePath,
            )
        }
        startInternalLocked(bundle = bundle, tunFd = tunFd, restartReason = null)
    }

    fun stop(configId: String, preserveBundle: Boolean = false): Map<String, Any?> = synchronized(lock) {
        val pid = activePid
        if (pid == null) {
            if (!preserveBundle) {
                lastBundle = null
                currentTunFd = -1
            }
            lastMessage = "No active runtime session."
            return@synchronized mapOf(
                "state" to "stopped",
                "success" to true,
                "message" to lastMessage,
                "configId" to configId,
            )
        }

        val stopped = XrayNativeBridge.stop(pid)
        activePid = null
        sessionId = null
        activeConfigId = null
        currentDeviceVpnMode = false
        if (!preserveBundle) {
            lastBundle = null
            currentTunFd = -1
        }
        lastMessage = if (stopped) {
            "Runtime stopped."
        } else {
            "Failed to stop runtime cleanly."
        }
        return@synchronized mapOf(
            "state" to if (stopped) "stopped" else "error",
            "success" to stopped,
            "message" to lastMessage,
            "configId" to configId,
            "logFilePath" to lastLogFile?.absolutePath,
        )
    }

    fun status(): Map<String, Any?> = synchronized(lock) {
        restoreIfNeededLocked()
        val pid = activePid
        val running = pid != null && XrayNativeBridge.isRunning(pid)
        if (!running && activePid != null) {
            activePid = null
            sessionId = null
            activeConfigId = null
        }
        mapOf(
            "state" to if (running) "running" else "idle",
            "success" to true,
            "message" to if (running) lastMessage else lastMessage.ifBlank { "Runtime is idle." },
            "configId" to activeConfigId,
            "sessionId" to sessionId,
            "httpPort" to currentHttpPort,
            "socksPort" to currentSocksPort,
            "deviceVpnMode" to currentDeviceVpnMode,
            "logFilePath" to lastLogFile?.absolutePath,
        )
    }

    fun isActiveProxyPort(httpPort: Int): Boolean = synchronized(lock) {
        restoreIfNeededLocked()
        val pid = activePid ?: return@synchronized false
        XrayNativeBridge.isRunning(pid) && currentHttpPort == httpPort
    }

    fun isDeviceVpnMode(): Boolean = synchronized(lock) {
        restoreIfNeededLocked()
        currentDeviceVpnMode
    }

    fun pingViaTransientRuntime(bundle: RuntimeBundle, url: String): Map<String, Any?> {
        val pid = XrayNativeBridge.start(
            bundle.binaryFile.absolutePath,
            bundle.configFile.absolutePath,
            bundle.assetDir.absolutePath,
            bundle.workDir.absolutePath,
            bundle.logFile.absolutePath,
            -1,
        )
        if (pid <= 0L || !XrayNativeBridge.isRunning(pid)) {
            val outputTail = tailLog(bundle.logFile)
            return mapOf(
                "success" to false,
                "message" to buildString {
                    append("Failed to launch a transient runtime for ping")
                    if (pid < 0L) {
                        append(" (errno=")
                        append(-pid)
                        append(')')
                    }
                    append('.')
                    if (outputTail.isNotBlank()) {
                        append("\n")
                        append(outputTail)
                    }
                },
                "latencyMs" to null,
                "logFilePath" to bundle.logFile.absolutePath,
            )
        }
        try {
            Thread.sleep(900)
            val result = pingProxy(httpPort = bundle.httpPort, url = url)
            return result + mapOf("logFilePath" to bundle.logFile.absolutePath)
        } finally {
            XrayNativeBridge.stop(pid)
        }
    }

    fun pingProxy(httpPort: Int, url: String): Map<String, Any?> {
        synchronized(lock) {
            restoreIfNeededLocked()
        }
        val firstAttempt = performProxyPing(httpPort, url)
        if (firstAttempt["success"] == true) {
            return firstAttempt
        }

        synchronized(lock) {
            val bundle = lastBundle
            if (bundle != null) {
                val restarted = startInternalLocked(
                    bundle = bundle.copy(
                        logFile = nextRestartLogFile(bundle),
                    ),
                    tunFd = currentTunFd,
                    restartReason = "Runtime was restarted after the proxy probe failed.",
                )
                if (restarted["success"] == true) {
                    Thread.sleep(900)
                    val retry = performProxyPing(httpPort, url)
                    if (retry["success"] == true) {
                        return retry + mapOf(
                            "message" to ((retry["message"] as? String) ?: "Proxy recovered after restart."),
                        )
                    }
                    return retry + mapOf(
                        "message" to buildString {
                            append((retry["message"] as? String) ?: "Proxy ping failed after restart.")
                            append(" Runtime was restarted once automatically.")
                        },
                    )
                }
            }
        }
        return firstAttempt
    }

    fun pingTargetDirect(host: String, port: Int, reason: String): Map<String, Any?> {
        val start = System.nanoTime()
        return try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress(host, port), 4000)
            }
            val latencyMs = ((System.nanoTime() - start) / 1_000_000L).toInt()
            mapOf(
                "success" to true,
                "latencyMs" to latencyMs,
                "message" to "Direct TCP latency to $host:$port: ${latencyMs} ms\n$reason",
            )
        } catch (error: Exception) {
            mapOf(
                "success" to false,
                "latencyMs" to null,
                "message" to "Direct TCP probe failed for $host:$port: ${error.message ?: error.javaClass.simpleName}\n$reason",
            )
        }
    }

    private fun buildReadyMessage(bundle: RuntimeBundle): String {
        return buildString {
            append("Runtime accepted the generated config. Ready to launch.")
            append(" HTTP 127.0.0.1:")
            append(bundle.httpPort)
            append(", SOCKS 127.0.0.1:")
            append(bundle.socksPort)
            if (bundle.enableDeviceVpn) {
                append(". Full-device tunnel mode is configured.")
            }
        }
    }

    private fun performProxyPing(httpPort: Int, url: String): Map<String, Any?> {
        val start = System.nanoTime()
        return try {
            val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", httpPort))
            val connection = (URL(url).openConnection(proxy) as HttpURLConnection).apply {
                connectTimeout = 4000
                readTimeout = 4000
                requestMethod = "GET"
                instanceFollowRedirects = true
                useCaches = false
            }
            connection.inputStream.use { it.readBytes() }
            val latencyMs = ((System.nanoTime() - start) / 1_000_000L).toInt()
            mapOf(
                "success" to true,
                "latencyMs" to latencyMs,
                "message" to "Proxy latency to $url: ${latencyMs} ms",
            )
        } catch (error: Exception) {
            mapOf(
                "success" to false,
                "latencyMs" to null,
                "message" to "Proxy ping failed: ${error.message ?: error.javaClass.simpleName}",
            )
        }
    }

    private fun restoreIfNeededLocked() {
        val pid = activePid
        if (pid == null || XrayNativeBridge.isRunning(pid)) {
            return
        }
        activePid = null
        sessionId = null
        activeConfigId = null
        val bundle = lastBundle ?: run {
            currentDeviceVpnMode = false
            lastMessage = "Runtime stopped."
            return
        }
        val restartLog = nextRestartLogFile(bundle)
        startInternalLocked(
            bundle = bundle.copy(logFile = restartLog),
            tunFd = currentTunFd,
            restartReason = "Runtime restarted automatically after an unexpected stop.",
        )
    }

    private fun nextRestartLogFile(bundle: RuntimeBundle): File {
        val logRoot = bundle.logFile.parentFile ?: bundle.workDir
        logRoot.mkdirs()
        val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        return File(logRoot, "${stamp}_${bundle.configId}_restart.log")
    }

    private fun startInternalLocked(
        bundle: RuntimeBundle,
        tunFd: Int,
        restartReason: String?,
    ): Map<String, Any?> {
        val currentPid = activePid
        if (currentPid != null && XrayNativeBridge.isRunning(currentPid)) {
            XrayNativeBridge.stop(currentPid)
        }

        val pid = XrayNativeBridge.start(
            bundle.binaryFile.absolutePath,
            bundle.configFile.absolutePath,
            bundle.assetDir.absolutePath,
            bundle.workDir.absolutePath,
            bundle.logFile.absolutePath,
            tunFd,
        )
        if (pid <= 0L || !XrayNativeBridge.isRunning(pid)) {
            val outputTail = tailLog(bundle.logFile)
            lastMessage = buildString {
                append("Failed to launch runtime")
                if (pid < 0L) {
                    append(" (errno=")
                    append(-pid)
                    append(')')
                }
                append('.')
                if (outputTail.isNotBlank()) {
                    append("\n")
                    append(outputTail)
                }
            }
            activePid = null
            sessionId = null
            activeConfigId = null
            return mapOf(
                "state" to "error",
                "success" to false,
                "message" to lastMessage,
                "configId" to bundle.configId,
                "displayName" to bundle.displayName,
                "httpPort" to bundle.httpPort,
                "socksPort" to bundle.socksPort,
                "deviceVpnMode" to bundle.enableDeviceVpn,
                "logFilePath" to bundle.logFile.absolutePath,
                "outputTail" to outputTail,
            )
        }

        sessionId = UUID.randomUUID().toString()
        activeConfigId = bundle.configId
        activePid = pid
        currentHttpPort = bundle.httpPort
        currentSocksPort = bundle.socksPort
        currentDeviceVpnMode = bundle.enableDeviceVpn
        lastLogFile = bundle.logFile
        lastBundle = bundle
        currentTunFd = tunFd
        lastMessage = buildString {
            append("Runtime started. HTTP proxy 127.0.0.1:")
            append(bundle.httpPort)
            append(", SOCKS 127.0.0.1:")
            append(bundle.socksPort)
            if (bundle.enableDeviceVpn) {
                append(". Full-device tunnel is active.")
            }
            if (!restartReason.isNullOrBlank()) {
                append(' ')
                append(restartReason)
            }
        }
        return mapOf(
            "state" to "running",
            "success" to true,
            "message" to lastMessage,
            "configId" to bundle.configId,
            "displayName" to bundle.displayName,
            "sessionId" to sessionId,
            "httpPort" to bundle.httpPort,
            "socksPort" to bundle.socksPort,
            "deviceVpnMode" to bundle.enableDeviceVpn,
            "logFilePath" to bundle.logFile.absolutePath,
        )
    }

    private fun tailLog(file: File, maxChars: Int = 4000): String {
        return runCatching {
            if (!file.exists()) return@runCatching ""
            val text = file.readText()
            if (text.length <= maxChars) text.trim() else text.takeLast(maxChars).trim()
        }.getOrDefault("")
    }
}
