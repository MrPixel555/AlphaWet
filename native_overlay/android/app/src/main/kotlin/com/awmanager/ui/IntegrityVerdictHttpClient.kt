package com.awmanager.ui

import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedWriter
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URL
import java.nio.charset.StandardCharsets

internal data class IntegrityDecodedVerdict(
    val requestPackageName: String,
    val requestHash: String,
    val requestTimestampMillis: Long,
    val deviceRecognitionVerdict: Set<String>,
    val appRecognitionVerdict: Set<String>,
    val certificateDigests: Set<String>,
    val meetsDeviceIntegrity: Boolean,
    val allowed: Boolean,
    val rawPayload: String,
)

internal object IntegrityVerdictHttpClient {
    private const val connectTimeoutMs = 12_000
    private const val readTimeoutMs = 20_000

    fun decodeAndValidate(
        verdictUrl: String,
        requestData: IntegrityCheckRequestData,
        integrityToken: String,
        requiredLabel: String,
        useActiveTunnelProxy: Boolean,
        proxyHttpPort: Int,
    ): IntegrityDecodedVerdict {
        val proxy = if (useActiveTunnelProxy && proxyHttpPort in 1..65535) {
            Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", proxyHttpPort))
        } else {
            Proxy.NO_PROXY
        }

        val connection = (URL(verdictUrl).openConnection(proxy) as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = connectTimeoutMs
            readTimeout = readTimeoutMs
            doOutput = true
            doInput = true
            useCaches = false
            setRequestProperty("Content-Type", "application/json; charset=utf-8")
            setRequestProperty("Accept", "application/json")
        }

        val payload = JSONObject()
            .put("integrityToken", integrityToken)
            .put("requestHash", requestData.requestHash)
            .put("packageName", requestData.packageName)
            .put("configId", requestData.configId)
            .put("issuedAtMillis", requestData.issuedAtMillis)
            .toString()

        connection.outputStream.use { output ->
            BufferedWriter(OutputStreamWriter(output, StandardCharsets.UTF_8)).use { writer ->
                writer.write(payload)
            }
        }

        val statusCode = connection.responseCode
        val responseText = runCatching {
            val stream = if (statusCode in 200..299) connection.inputStream else connection.errorStream
            stream?.bufferedReader(StandardCharsets.UTF_8)?.use { it.readText() }.orEmpty()
        }.getOrDefault("")

        if (statusCode !in 200..299) {
            throw SecurityException("Integrity verdict endpoint rejected the request ($statusCode). $responseText")
        }

        val json = JSONObject(responseText)
        val requestPackageName = json.optString("requestPackageName", "")
        val requestHash = json.optString("requestHash", "")
        val requestTimestampMillis = json.optLong("requestTimestampMillis", 0L)
        val deviceLabels = json.optJSONArray("deviceRecognitionVerdict").toStringSet()
        val appLabels = json.optJSONArray("appRecognitionVerdict").toStringSet()
        val certificateDigests = json.optJSONArray("certificateSha256Digest").toStringSet()
        val meetsDeviceIntegrity = json.optBoolean("meetsRequiredDeviceIntegrity", false) &&
            deviceLabels.contains(requiredLabel)
        val allowed = json.optBoolean("allowed", false)

        return IntegrityDecodedVerdict(
            requestPackageName = requestPackageName,
            requestHash = requestHash,
            requestTimestampMillis = requestTimestampMillis,
            deviceRecognitionVerdict = deviceLabels,
            appRecognitionVerdict = appLabels,
            certificateDigests = certificateDigests,
            meetsDeviceIntegrity = meetsDeviceIntegrity,
            allowed = allowed,
            rawPayload = responseText,
        )
    }

    private fun JSONArray?.toStringSet(): Set<String> {
        if (this == null) {
            return emptySet()
        }
        val values = LinkedHashSet<String>()
        for (index in 0 until length()) {
            optString(index)?.trim()?.takeIf { it.isNotEmpty() }?.let(values::add)
        }
        return values
    }
}
