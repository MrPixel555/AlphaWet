package com.awmanager.ui

import android.content.Context
import android.os.Build
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

        val binaryResolution = resolveRuntimeBinary(throwOnMissing = false)
        if (configJson != null && binaryResolution.binaryFile != null) {
            val bundle = prepareBundleFromRaw(
                configId = "ping_$configId",
                displayName = "$displayName (Ping)",
                configJson = configJson,
                httpPort = httpPort,
                socksPort = socksPort,
                enableDeviceVpn = false,
                binaryFile = binaryResolution.binaryFile,
                executionMode = binaryResolution.executionMode,
            )
            return XrayCoreRuntimeManager.pingViaTransientRuntime(bundle = bundle, url = url)
        }

        if (targetHost != null && targetPort != null) {
            val fallbackReason = if (binaryResolution.binaryFile == null) {
                "Xray runtime asset is unavailable on this device, so a direct TCP reachability probe was used instead of a proxy-to-google test. ${binaryResolution.message ?: ""}".trim()
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
                binaryResolution.binaryFile == null ->
                    binaryResolution.message.orEmpty().ifBlank {
                        "Xray runtime asset was not available and no direct host/port fallback was provided for ping."
                    }
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
        val binaryResolution = resolveRuntimeBinary(throwOnMissing = true)
        val binaryFile = requireNotNull(binaryResolution.binaryFile) { binaryResolution.message ?: "Runtime binary is missing." }
        return prepareBundleFromRaw(
            configId = configId,
            displayName = displayName,
            configJson = configJson,
            httpPort = httpPort,
            socksPort = socksPort,
            enableDeviceVpn = enableDeviceVpn,
            binaryFile = binaryFile,
            executionMode = binaryResolution.executionMode,
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
        executionMode: RuntimeExecutionMode,
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
            executionMode = executionMode,
        )
    }

    private fun resolveRuntimeBinary(throwOnMissing: Boolean): RuntimeBinaryResolution {
        val abi = preferredRuntimeAbi()
        val assetPath = "flutter_assets/assets/xray/android/$abi/xray"
        if (!assetExists(assetPath)) {
            val optionalX64 = abi == "x86_64"
            val message = if (optionalX64) {
                "No bundled Xray binary for ABI $abi. Add assets/xray/android/$abi/xray or run on an arm64 device."
            } else {
                "Bundled Xray binary was not found for ABI $abi. Put the binary at assets/xray/android/$abi/xray and rebuild."
            }
            if (throwOnMissing) {
                throw IllegalStateException(message)
            }
            return RuntimeBinaryResolution(null, RuntimeExecutionMode.DIRECT, message)
        }

        val extracted = extractAssetBinaryToPrivateDir(assetPath, abi)
        if (setExecutable(extracted)) {
            return RuntimeBinaryResolution(extracted, RuntimeExecutionMode.DIRECT, null)
        }

        if (hasWorkingSu()) {
            val rootedCopy = copyBinaryToRootExecLocation(extracted, abi)
            if (rootedCopy != null) {
                return RuntimeBinaryResolution(rootedCopy, RuntimeExecutionMode.ROOT_SU, null)
            }
        }

        val message = buildString {
            append("Xray binary for ABI ")
            append(abi)
            append(" was bundled, but Android refused local execution from ")
            append(extracted.absolutePath)
            append(" and no rooted fallback could be prepared.")
        }
        if (throwOnMissing) {
            throw IllegalStateException(message)
        }
        return RuntimeBinaryResolution(null, RuntimeExecutionMode.DIRECT, message)
    }

    private fun preferredRuntimeAbi(): String {
        val supported = Build.SUPPORTED_ABIS?.toList().orEmpty()
        return when {
            supported.any { it == "arm64-v8a" } -> "arm64-v8a"
            supported.any { it == "x86_64" } -> "x86_64"
            supported.isNotEmpty() -> supported.first()
            else -> "arm64-v8a"
        }
    }

    private fun extractAssetBinaryToPrivateDir(assetPath: String, abi: String): File {
        val runtimeRoot = File(context.filesDir, "xray_runtime/bin/$abi").apply { mkdirs() }
        val target = File(runtimeRoot, "xray")
        context.assets.open(assetPath).use { input ->
            FileOutputStream(target).use { output -> input.copyTo(output) }
        }
        target.setReadable(true, true)
        target.setWritable(true, true)
        return target
    }

    private fun setExecutable(file: File): Boolean {
        return try {
            file.setReadable(true, true)
            file.setWritable(true, true)
            file.setExecutable(true, true)
            file.canExecute()
        } catch (_: Exception) {
            false
        }
    }

    private fun hasWorkingSu(): Boolean {
        return try {
            val proc = ProcessBuilder("su", "-c", "id").redirectErrorStream(true).start()
            val output = proc.inputStream.bufferedReader().use { it.readText() }
            val exitCode = proc.waitFor()
            exitCode == 0 && output.contains("uid=0")
        } catch (_: Exception) {
            false
        }
    }

    private fun copyBinaryToRootExecLocation(source: File, abi: String): File? {
        val rootDir = File("/data/local/tmp/aw_manager_ui/$abi")
        return try {
            val prep = ProcessBuilder(
                "su",
                "-c",
                "mkdir -p ${rootDir.absolutePath} && cp ${source.absolutePath} ${rootDir.absolutePath}/xray && chmod 755 ${rootDir.absolutePath}/xray"
            ).redirectErrorStream(true).start()
            prep.inputStream.bufferedReader().use { it.readText() }
            val exitCode = prep.waitFor()
            val rootedBinary = File(rootDir, "xray")
            if (exitCode == 0 && rootedBinary.exists()) rootedBinary else null
        } catch (_: Exception) {
            null
        }
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

enum class RuntimeExecutionMode {
    DIRECT,
    ROOT_SU,
}

data class RuntimeBinaryResolution(
    val binaryFile: File?,
    val executionMode: RuntimeExecutionMode,
    val message: String?,
)

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
    val executionMode: RuntimeExecutionMode,
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
        val proc = createRuntimeProcess(bundle, testConfigOnly = true)
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
                "rawOutput" to output,
            )
        } else {
            mapOf(
                "state" to "failed",
                "success" to false,
                "message" to output.ifBlank { "Xray rejected the generated config." },
                "rawOutput" to output,
                "exitCode" to exitCode,
            )
        }
    }

    fun start(bundle: RuntimeBundle): Map<String, Any?> {
        synchronized(lock) {
            stopInternal("Restarting Xray core for ${bundle.configId}.")
            val newSessionId = UUID.randomUUID().toString()
            val proc = createRuntimeProcess(bundle, testConfigOnly = false)
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
        val proc = createRuntimeProcess(bundle, testConfigOnly = false)
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

    private fun createRuntimeProcess(bundle: RuntimeBundle, testConfigOnly: Boolean): Process {
        val args = mutableListOf("run")
        if (testConfigOnly) {
            args += "-test"
        }
        args += listOf("-c", bundle.configFile.absolutePath)
        val commandLine = buildCommandLine(bundle.binaryFile, args, bundle.assetDir)
        val builder = when (bundle.executionMode) {
            RuntimeExecutionMode.DIRECT -> ProcessBuilder(commandLine)
            RuntimeExecutionMode.ROOT_SU -> ProcessBuilder("su", "-c", commandLine.joinToString(" ") { shellQuote(it) })
        }
        builder.redirectErrorStream(true)
        builder.directory(bundle.binaryFile.parentFile)
        return builder.start()
    }

    private fun buildCommandLine(binaryFile: File, args: List<String>, assetDir: File): List<String> {
        val env = "XRAY_LOCATION_ASSET=${shellQuote(assetDir.absolutePath)}"
        val binary = shellQuote(binaryFile.absolutePath)
        val fullArgs = args.joinToString(" ") { shellQuote(it) }
        return listOf("sh", "-c", "$env exec $binary $fullArgs")
    }

    private fun shellQuote(value: String): String {
        return "'" + value.replace("'", "'\\''") + "'"
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
