package com.awmanager.ui

import android.content.Context
import android.os.Build
import io.flutter.plugin.common.MethodCall
import java.io.File
import java.io.FileOutputStream
import java.net.InetSocketAddress
import java.net.Socket
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
        val binRoot = File(runtimeRoot, "bin").apply { mkdirs() }
        val logRoot = File(runtimeRoot, "logs").apply { mkdirs() }

        val configFile = File(configRoot, "$configId.json")
        configFile.writeText(configJson)

        val binaryFile = copyBinaryForCurrentAbi(binRoot)
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
            logFile = logFile,
            httpPort = httpPort,
            socksPort = socksPort,
            enableDeviceVpn = enableDeviceVpn,
        )
    }

    private fun copyBinaryForCurrentAbi(binRoot: File): File {
        val supportedAbis = Build.SUPPORTED_ABIS?.toList().orEmpty()
        val assetCandidates = supportedAbis.mapNotNull { abi ->
            when (abi) {
                "arm64-v8a" -> "flutter_assets/assets/xray/android/arm64-v8a/xray"
                "x86_64" -> "flutter_assets/assets/xray/android/x86_64/xray"
                else -> null
            }
        }

        for (assetPath in assetCandidates) {
            if (!assetExists(assetPath)) {
                continue
            }
            val target = File(binRoot, "xray")
            context.assets.open(assetPath).use { input ->
                FileOutputStream(target).use { output -> input.copyTo(output) }
            }
            target.setReadable(true, true)
            target.setExecutable(true, true)
            target.setWritable(true, true)
            return target
        }

        throw IllegalStateException(
            "No packaged Xray binary was found for ABI(s): ${supportedAbis.joinToString()}. Place it under assets/xray/android/<abi>/xray before building.",
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
    val logFile: File,
    val httpPort: Int,
    val socksPort: Int,
    val enableDeviceVpn: Boolean,
)

object XrayCoreRuntimeManager {
    private val lock = Any()
    private var process: Process? = null
    private var sessionId: String? = null
    private var activeConfigId: String? = null
    private var lastMessage: String = "Idle."
    private var logPumpThread: Thread? = null
    private var lastLogFile: File? = null
    private var currentHttpPort: Int = 10808
    private var currentSocksPort: Int = 10809
    private var currentDeviceVpnMode: Boolean = false

    fun validate(bundle: RuntimeBundle): Map<String, Any?> {
        val builder = ProcessBuilder(
            bundle.binaryFile.absolutePath,
            "run",
            "-test",
            "-c",
            bundle.configFile.absolutePath,
        )
        builder.redirectErrorStream(true)
        builder.directory(bundle.binaryFile.parentFile)
        builder.environment()["XRAY_LOCATION_ASSET"] = bundle.assetDir.absolutePath
        val proc = builder.start()
        val output = proc.inputStream.bufferedReader().use { it.readText() }
        val exitCode = proc.waitFor()
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
                    if (output.isNotBlank()) {
                        append(": ")
                        append(output.lines().takeLast(6).joinToString(" | "))
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
            val builder = ProcessBuilder(
                bundle.binaryFile.absolutePath,
                "run",
                "-c",
                bundle.configFile.absolutePath,
            )
            builder.redirectErrorStream(true)
            builder.directory(bundle.binaryFile.parentFile)
            builder.environment()["XRAY_LOCATION_ASSET"] = bundle.assetDir.absolutePath
            val proc = builder.start()

            process = proc
            sessionId = newSessionId
            activeConfigId = bundle.configId
            currentHttpPort = bundle.httpPort
            currentSocksPort = bundle.socksPort
            currentDeviceVpnMode = bundle.enableDeviceVpn
            lastMessage = "Launching Xray core..."
            lastLogFile = bundle.logFile
            startLogPump(proc, bundle.logFile)
        }

        val ready = waitForPorts(bundle.socksPort, bundle.httpPort)
        synchronized(lock) {
            val currentProcess = process
            if (currentProcess == null) {
                return mapOf(
                    "state" to "failed",
                    "success" to false,
                    "message" to (lastMessage.ifBlank { "Xray core process was not retained." }),
                    "sessionId" to sessionId,
                )
            }
            if (!currentProcess.isAlive) {
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
            val alive = process?.isAlive == true
            return mapOf(
                "state" to if (alive) "connected" else "idle",
                "success" to alive,
                "message" to lastMessage,
                "sessionId" to sessionId,
                "configId" to activeConfigId,
                "httpPort" to currentHttpPort,
                "socksPort" to currentSocksPort,
                "deviceVpnRequested" to currentDeviceVpnMode,
            )
        }
    }

    private fun stopInternal(reason: String) {
        process?.let { proc ->
            if (proc.isAlive) {
                proc.destroy()
                try {
                    proc.waitFor()
                } catch (_: InterruptedException) {
                    proc.destroyForcibly()
                }
            }
        }
        logPumpThread?.interrupt()
        process = null
        sessionId = null
        activeConfigId = null
        logPumpThread = null
        currentDeviceVpnMode = false
        lastMessage = reason
    }

    private fun startLogPump(proc: Process, logFile: File) {
        val thread = Thread {
            try {
                proc.inputStream.bufferedReader().useLines { sequence ->
                    logFile.parentFile?.mkdirs()
                    sequence.forEach { line ->
                        logFile.appendText(line + "\n")
                        synchronized(lock) {
                            if (line.isNotBlank()) {
                                lastMessage = line.trim()
                            }
                        }
                    }
                }
            } catch (_: Exception) {
                // Ignore log pump failures; process state is checked separately.
            }
        }
        thread.isDaemon = true
        thread.start()
        logPumpThread = thread
    }

    private fun waitForPorts(socksPort: Int, httpPort: Int, timeoutMs: Long = 3000L): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            synchronized(lock) {
                if (process?.isAlive != true) {
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
            Socket().use { socket ->
                socket.connect(InetSocketAddress("127.0.0.1", port), 200)
                true
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun buildFailureMessage(): String {
        val logFile = lastLogFile
        if (logFile != null && logFile.exists()) {
            val tail = logFile.readLines().takeLast(6).joinToString(" | ").trim()
            if (tail.isNotEmpty()) {
                return "Xray core exited early: $tail"
            }
        }
        return "Xray core exited before the local proxy ports became available."
    }
}
