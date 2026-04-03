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
        const val CHANNEL = "aw_manager_ui/xray_core"
        private const val PACKAGED_BINARY_NAME = "libxraycore.so"
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

    fun pingProxy(call: MethodCall): Map<String, Any?> {
        val httpPort = call.argument<Int>("httpPort") ?: 10808
        val socksPort = call.argument<Int>("socksPort") ?: 10809
        val url = call.argument<String>("url")?.trim().takeUnless { it.isNullOrEmpty() }
            ?: "https://www.google.com/generate_204"
        val configJson = call.argument<String>("configJson")?.trim().takeUnless { it.isNullOrEmpty() }
        val configId = call.argument<String>("configId")?.trim().takeUnless { it.isNullOrEmpty() }
            ?: "ping"
        val displayName = call.argument<String>("displayName")?.trim().takeUnless { it.isNullOrEmpty() }
            ?: configId
        val targetHost = call.argument<String>("targetHost")?.trim().takeUnless { it.isNullOrEmpty() }
        val targetPort = call.argument<Int>("targetPort")

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
                "Packaged Xray runtime was not found, so a direct TCP reachability probe was used instead of a proxy-to-google test."
            } else {
                "Xray JSON was unavailable, so a direct TCP reachability probe was used instead of a proxy-to-google test."
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
                    "Packaged Xray runtime was not found and no direct host/port fallback was available for ping."
                else ->
                    "Ping requires either a running core, a ready Xray config, or a host/port target."
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
        val candidateNames = listOf(
            PACKAGED_BINARY_NAME,
            "xray",
            "libxray.so",
            "libxraymain.so",
        )
        val roots = linkedSetOf<File>()
        context.applicationInfo.nativeLibraryDir?.let { roots += File(it) }
        context.applicationInfo.nativeLibraryRootDir?.let { roots += File(it) }
        context.applicationInfo.sourceDir?.let { roots += File(it).parentFile }

        for (root in roots) {
            if (!root.exists()) {
                continue
            }
            val direct = candidateNames.firstNotNullOfOrNull { name ->
                val candidate = File(root, name)
                candidate.takeIf { it.exists() }
            }
            if (direct != null) {
                direct.setReadable(true, true)
                direct.setExecutable(true, true)
                return direct
            }
            root.walkTopDown().maxDepth(2).forEach { candidate ->
                if (candidate.isFile && candidate.name in candidateNames) {
                    candidate.setReadable(true, true)
                    candidate.setExecutable(true, true)
                    return candidate
                }
            }
        }
        return null
    }

    private fun buildMissingRuntimeMessage(): String {
        val nativeLibraryDir = context.applicationInfo.nativeLibraryDir ?: "unavailable"
        val nativeLibraryRootDir = context.applicationInfo.nativeLibraryRootDir ?: "unavailable"
        val listing = try {
            val dir = File(nativeLibraryDir)
            if (dir.exists()) {
                dir.listFiles()?.joinToString(", ") { it.name } ?: "<empty>"
            } else {
                "<dir-missing>"
            }
        } catch (_: Exception) {
            "<unreadable>"
        }
        return "Packaged Xray runtime was not found in nativeLibraryDir ($nativeLibraryDir). " +
            "nativeLibraryRootDir=$nativeLibraryRootDir. Files seen: $listing. " +
            "This usually means the .so was packaged inside the APK but not extracted to the filesystem. " +
            "Enable native library extraction by setting android:extractNativeLibs=\"true\" or packaging.jniLibs.useLegacyPackaging=true before building."
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

        val ready = waitForPorts(process, bundle.socksPort, bundle.httpPort)
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

    fun isActiveProxyPort(httpPort: Int): Boolean {
        synchronized(lock) {
            return process?.isAlive == true && currentHttpPort == httpPort
        }
    }

    fun pingProxy(httpPort: Int, url: String): Map<String, Any?> {
        synchronized(lock) {
            if (process?.isAlive != true) {
                return mapOf(
                    "success" to false,
                    "message" to "Xray core is not running. A transient probe or a direct fallback is required.",
                )
            }
        }
        return performHttpProxyProbe(httpPort = httpPort, url = url)
    }

    fun pingViaTransientRuntime(bundle: RuntimeBundle, url: String): Map<String, Any?> {
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
        startLogPump(proc, bundle.logFile)
        return try {
            val ready = waitForPorts(proc, bundle.socksPort, bundle.httpPort, 5000L)
            if (!ready) {
                mapOf(
                    "success" to false,
                    "message" to buildFailureMessage(bundle.logFile, "Transient Xray probe did not become ready"),
                )
            } else {
                val result = performHttpProxyProbe(httpPort = bundle.httpPort, url = url)
                val originalMessage = result["message"] as String? ?: "Latency probe finished."
                result + mapOf("message" to "$originalMessage (measured via a transient Xray runtime)")
            }
        } finally {
            stopProcessQuietly(proc)
        }
    }

    fun pingTargetDirect(host: String, port: Int, reason: String): Map<String, Any?> {
        return try {
            val startedAt = System.nanoTime()
            Socket().use { socket ->
                socket.connect(InetSocketAddress(host, port), 5000)
            }
            val elapsedMs = ((System.nanoTime() - startedAt) / 1_000_000L).coerceAtLeast(1L)
            mapOf(
                "success" to true,
                "latencyMs" to elapsedMs,
                "message" to "TCP reachability to $host:$port succeeded in ${elapsedMs} ms. $reason",
            )
        } catch (error: Exception) {
            mapOf(
                "success" to false,
                "message" to "TCP reachability to $host:$port failed: ${error.message ?: error.javaClass.simpleName}. $reason",
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

    private fun performHttpProxyProbe(httpPort: Int, url: String): Map<String, Any?> {
        val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", httpPort))
        val startedAt = System.nanoTime()
        val connection = (URL(url).openConnection(proxy) as HttpURLConnection).apply {
            connectTimeout = 8000
            readTimeout = 8000
            instanceFollowRedirects = false
            requestMethod = "GET"
            setRequestProperty("User-Agent", "AW-Manager-UI/1.0")
        }

        return try {
            val code = connection.responseCode
            connection.inputStream.use { input ->
                while (input.read() != -1) {
                    break
                }
            }
            val elapsedMs = ((System.nanoTime() - startedAt) / 1_000_000L).coerceAtLeast(1L)
            if (code in 200..399 || code == 204) {
                mapOf(
                    "success" to true,
                    "latencyMs" to elapsedMs,
                    "message" to "Proxy path to google.com is reachable in ${elapsedMs} ms (HTTP $code).",
                )
            } else {
                mapOf(
                    "success" to false,
                    "message" to "Proxy reached the remote endpoint, but google.com returned HTTP $code.",
                )
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun stopInternal(reason: String) {
        process?.let { proc ->
            stopProcessQuietly(proc)
        }
        logPumpThread?.interrupt()
        process = null
        sessionId = null
        activeConfigId = null
        logPumpThread = null
        currentDeviceVpnMode = false
        lastMessage = reason
    }

    private fun stopProcessQuietly(proc: Process) {
        if (proc.isAlive) {
            proc.destroy()
            try {
                proc.waitFor()
            } catch (_: InterruptedException) {
                proc.destroyForcibly()
            }
        }
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

    private fun waitForPorts(
        targetProcess: Process?,
        socksPort: Int,
        httpPort: Int,
        timeoutMs: Long = 3000L,
    ): Boolean {
        val proc = targetProcess ?: return false
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (!proc.isAlive) {
                return false
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

    private fun buildFailureMessage(): String = buildFailureMessage(lastLogFile, "Xray core exited early")

    private fun buildFailureMessage(logFile: File?, prefix: String): String {
        if (logFile != null && logFile.exists()) {
            val tail = logFile.readLines().takeLast(6).joinToString(" | ").trim()
            if (tail.isNotEmpty()) {
                return "$prefix: $tail"
            }
        }
        return "$prefix before the local proxy ports became available."
    }
}
