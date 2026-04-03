package com.awmanager.ui

import android.content.Context
import android.os.Build
import io.flutter.plugin.common.MethodCall
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

class XrayCoreRuntimeBridge(private val context: Context) {
    companion object {
        const val CHANNEL = "aw_manager_ui/xray_core"
    }

    fun validateConfig(call: MethodCall): Map<String, Any?> {
        val bundle = prepareBundle(call)
        return XrayCoreRuntimeManager.validate(bundle)
    }

    fun startCore(call: MethodCall): Map<String, Any?> {
        val bundle = prepareBundle(call)
        return XrayCoreRuntimeManager.start(bundle)
    }

    fun stopCore(call: MethodCall): Map<String, Any?> {
        val configId = call.argument<String>("configId") ?: "unknown"
        return XrayCoreRuntimeManager.stop(configId)
    }

    fun getCoreStatus(): Map<String, Any?> = XrayCoreRuntimeManager.status()

    private fun prepareBundle(call: MethodCall): RuntimeBundle {
        val configId = requireNotNull(call.argument<String>("configId")) { "configId is required." }
        val displayName = (call.argument<String>("displayName") ?: configId).trim()
        val configJson = requireNotNull(call.argument<String>("configJson")) { "configJson is required." }
        val httpPort = call.argument<Int>("httpPort") ?: 10808
        val socksPort = call.argument<Int>("socksPort") ?: 10809
        val enableDeviceVpn = call.argument<Boolean>("enableDeviceVpn") == true

        val runtimeRoot = File(context.filesDir, "xray_runtime").apply { mkdirs() }
        val configRoot = File(runtimeRoot, "configs").apply { mkdirs() }
        val assetsRoot = File(runtimeRoot, "assets").apply { mkdirs() }
        val workRoot = File(runtimeRoot, "work").apply { mkdirs() }
        val logRoot = File(runtimeRoot, "logs").apply { mkdirs() }

        val configFile = File(configRoot, "$configId.json")
        configFile.writeText(configJson)

        val binaryFile = resolvePackagedBinary()
        copyOptionalCommonAsset("geoip.dat", assetsRoot)
        copyOptionalCommonAsset("geosite.dat", assetsRoot)

        val logFileName = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date()) + "_$configId.log"
        val logFile = File(logRoot, logFileName)
        if (logFile.exists()) {
            logFile.delete()
        }
        logFile.parentFile?.mkdirs()
        logFile.createNewFile()

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
        val candidates = mutableListOf<File>()
        val nativeLibraryDir = context.applicationInfo.nativeLibraryDir?.trim().orEmpty()
        if (nativeLibraryDir.isNotEmpty()) {
            candidates += File(nativeLibraryDir, "libxraycore.so")
            candidates += File(nativeLibraryDir, "xray")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val rootDir = context.applicationInfo.nativeLibraryRootDir?.trim().orEmpty()
            if (rootDir.isNotEmpty()) {
                Build.SUPPORTED_ABIS?.forEach { abi ->
                    candidates += File(rootDir, "$abi/libxraycore.so")
                    candidates += File(rootDir, "$abi/xray")
                }
            }
        }

        val winner = candidates.firstOrNull { it.exists() && it.isFile }
        if (winner != null) {
            winner.setReadable(true, false)
            winner.setExecutable(true, false)
            return winner
        }

        throw IllegalStateException(
            buildString {
                append("Packaged Xray runtime was not found. Checked: ")
                append(candidates.joinToString())
                append(". Ensure tool/prepare_android_runtime.sh copied assets/xray/android/<abi>/xray to android/app/src/main/jniLibs/<abi>/libxraycore.so before building.")
            },
        )
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
                "message" to buildString {
                    append("Xray accepted the generated config. Ready to launch the core.")
                    append(" HTTP 127.0.0.1:")
                    append(bundle.httpPort)
                    append(", SOCKS 127.0.0.1:")
                    append(bundle.socksPort)
                    if (bundle.enableDeviceVpn) {
                        append(". Device-VPN mode is only scaffolded in this build.")
                    }
                },
                "sessionId" to sessionId,
            )
        } else {
            mapOf(
                "state" to "failed",
                "success" to false,
                "message" to buildString {
                    append("Xray rejected the config")
                    append(" (exit=")
                    append(exitCode)
                    append(")")
                    if (outputTail.isNotBlank()) {
                        append(": ")
                        append(outputTail)
                    }
                },
                "sessionId" to sessionId,
            )
        }
    }

    fun start(bundle: RuntimeBundle): Map<String, Any?> {
        synchronized(lock) {
            stopInternal("Switching runtime.")

            val newSessionId = "xray-${bundle.configId}-${UUID.randomUUID()}"
            val pid = XrayNativeBridge.start(
                bundle.binaryFile.absolutePath,
                bundle.configFile.absolutePath,
                bundle.assetDir.absolutePath,
                bundle.workDir.absolutePath,
                bundle.logFile.absolutePath,
            )
            if (pid <= 0L) {
                return mapOf(
                    "state" to "failed",
                    "success" to false,
                    "message" to "Failed to start Xray native runtime (pid=$pid).",
                    "sessionId" to null,
                )
            }

            activePid = pid
            sessionId = newSessionId
            activeConfigId = bundle.configId
            currentHttpPort = bundle.httpPort
            currentSocksPort = bundle.socksPort
            currentDeviceVpnMode = bundle.enableDeviceVpn
            lastMessage = "Launching Xray core..."
            lastLogFile = bundle.logFile
        }

        val ready = waitForPorts(bundle.socksPort, bundle.httpPort)
        synchronized(lock) {
            val pid = activePid
            if (pid == null) {
                return mapOf(
                    "state" to "failed",
                    "success" to false,
                    "message" to (lastMessage.ifBlank { "Xray native runtime was not retained." }),
                    "sessionId" to sessionId,
                )
            }
            if (!XrayNativeBridge.isRunning(pid)) {
                lastMessage = buildFailureMessage()
                return mapOf(
                    "state" to "failed",
                    "success" to false,
                    "message" to lastMessage,
                    "sessionId" to sessionId,
                )
            }

            lastMessage = if (ready) {
                buildString {
                    append("Xray core is running. Local HTTP: 127.0.0.1:")
                    append(bundle.httpPort)
                    append(", SOCKS: 127.0.0.1:")
                    append(bundle.socksPort)
                    if (bundle.enableDeviceVpn) {
                        append(". Device-VPN mode was requested, but the native TUN bridge is not implemented yet.")
                    }
                }
            } else {
                "Xray core process started, but the configured local inbound ports were not confirmed yet."
            }
            return mapOf(
                "state" to "connected",
                "success" to true,
                "message" to lastMessage,
                "sessionId" to sessionId,
            )
        }
    }

    fun stop(configId: String): Map<String, Any?> {
        synchronized(lock) {
            stopInternal("Stopped by user for $configId.")
            return mapOf(
                "state" to "idle",
                "success" to true,
                "message" to lastMessage,
                "sessionId" to null,
            )
        }
    }

    fun status(): Map<String, Any?> {
        synchronized(lock) {
            val alive = activePid?.let { XrayNativeBridge.isRunning(it) } == true
            return mapOf(
                "state" to if (alive) "connected" else "idle",
                "success" to alive,
                "message" to lastMessage,
                "sessionId" to sessionId,
                "configId" to activeConfigId,
                "httpPort" to currentHttpPort,
                "socksPort" to currentSocksPort,
                "deviceVpnRequested" to currentDeviceVpnMode,
                "pid" to activePid,
            )
        }
    }

    private fun stopInternal(reason: String) {
        activePid?.let { pid ->
            XrayNativeBridge.stop(pid)
        }
        activePid = null
        sessionId = null
        activeConfigId = null
        currentDeviceVpnMode = false
        lastMessage = reason
    }

    private fun waitForPorts(socksPort: Int, httpPort: Int, timeoutMs: Long = 3000L): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            synchronized(lock) {
                val pid = activePid
                if (pid == null || !XrayNativeBridge.isRunning(pid)) {
                    return false
                }
            }
            if (isLocalPortOpen(socksPort) || isLocalPortOpen(httpPort)) {
                return true
            }
            Thread.sleep(250)
        }
        return false
    }

    private fun isLocalPortOpen(port: Int): Boolean {
        return try {
            java.net.Socket().use { socket ->
                socket.connect(java.net.InetSocketAddress("127.0.0.1", port), 200)
                true
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun tailLog(logFile: File?): String {
        if (logFile == null || !logFile.exists()) {
            return ""
        }
        return runCatching {
            logFile.readLines().takeLast(6).joinToString(" | ").trim()
        }.getOrDefault("")
    }

    private fun buildFailureMessage(): String {
        val tail = tailLog(lastLogFile)
        if (tail.isNotEmpty()) {
            return "Xray core exited early: $tail"
        }
        return "Xray core exited before the local proxy ports became available."
    }
}
