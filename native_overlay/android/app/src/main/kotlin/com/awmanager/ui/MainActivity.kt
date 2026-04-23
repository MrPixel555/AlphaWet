package com.awmanager.ui

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.content.pm.ActivityInfo
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private lateinit var securityPolicyEnforcer: SecurityPolicyEnforcer

    override fun onCreate(savedInstanceState: Bundle?) {
        securityPolicyEnforcer = SecurityPolicyEnforcer(applicationContext)
        super.onCreate(savedInstanceState)
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
        runCatching {
            securityPolicyEnforcer.enforceStartupPolicy()
        }.onFailure {
            finishAffinity()
        }
    }

    private lateinit var bridge: XrayCoreRuntimeBridge
    private var pendingVpnPermissionResult: MethodChannel.Result? = null
    private val vpnPermissionRequestCode = 9912

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        bridge = XrayCoreRuntimeBridge(applicationContext)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            XrayCoreRuntimeBridge.CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "ensureVpnPermission" -> ensureVpnPermission(result)
                "isVpnPermissionGranted" -> result.success(isVpnPermissionGranted())
                "ensureManageStoragePermission" -> ensureManageStoragePermission(result)
                "performPostConnectSecurityCheck" -> executeAsync(result) { performPostConnectSecurityCheck(call) }
                "validateConfig" -> executeAsync(result) { bridge.validateConfig(call) }
                "startCore" -> executeAsync(result) { bridge.startCore(call) }
                "stopCore" -> executeAsync(result) { bridge.stopCore(call) }
                "pingProxy" -> executeAsync(result) { bridge.pingProxy(call) }
                "getCoreStatus" -> executeAsync(result) { bridge.getCoreStatus() }
                else -> result.error(
                    "XRAY_RUNTIME_ERROR",
                    "Unsupported method: ${call.method}",
                    null,
                )
            }
        }
    }

    private fun ensureVpnPermission(result: MethodChannel.Result) {
        val intent: Intent? = VpnService.prepare(this)
        if (intent == null) {
            result.success(true)
            return
        }
        pendingVpnPermissionResult = result
        @Suppress("DEPRECATION")
        startActivityForResult(intent, vpnPermissionRequestCode)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == vpnPermissionRequestCode) {
            val granted = resultCode == Activity.RESULT_OK
            pendingVpnPermissionResult?.success(granted)
            pendingVpnPermissionResult = null
        }
    }

    private fun isVpnPermissionGranted(): Boolean = VpnService.prepare(this) == null

    private fun ensureManageStoragePermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.success(true)
            return
        }
        if (Environment.isExternalStorageManager()) {
            result.success(true)
            return
        }
        runCatching {
            val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivity(intent)
        }.onFailure {
            runCatching {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
        }
        result.success(Environment.isExternalStorageManager())
    }

    private fun performPostConnectSecurityCheck(call: io.flutter.plugin.common.MethodCall): Map<String, Any?> {
        val configId = call.argument<String>("configId") ?: "unknown"
        val enableDeviceVpn = call.argument<Boolean>("enableDeviceVpn") == true
        val vpnPermissionGranted = call.argument<Boolean>("vpnPermissionGranted") == true
        val configJson = call.argument<String>("configJson")
        val httpPort = call.argument<Int>("httpPort") ?: 10808
        val socksPort = call.argument<Int>("socksPort") ?: 10809

        try {
            val integrity = securityPolicyEnforcer.performPostConnectPolicy(configId)
            if (enableDeviceVpn && vpnPermissionGranted && !configJson.isNullOrBlank()) {
                return bridge.startCore(
                    io.flutter.plugin.common.MethodCall(
                        "startCore",
                        mapOf(
                            "configId" to configId,
                            "displayName" to (call.argument<String>("displayName") ?: configId),
                            "configJson" to configJson,
                            "httpPort" to httpPort,
                            "socksPort" to socksPort,
                            "enableDeviceVpn" to true,
                        ),
                    ),
                )
            }
            return integrity
        } catch (error: Throwable) {
            runCatching {
                bridge.stopCore(io.flutter.plugin.common.MethodCall("stopCore", mapOf("configId" to configId)))
            }
            throw error
        }
    }

    private fun executeAsync(
        result: MethodChannel.Result,
        block: () -> Map<String, Any?>,
    ) {
        Thread {
            try {
                val payload = block()
                runOnUiThread { result.success(payload) }
            } catch (error: Throwable) {
                runOnUiThread {
                    result.error(
                        "XRAY_RUNTIME_ERROR",
                        error.message ?: error.javaClass.simpleName,
                        null,
                    )
                }
            }
        }.start()
    }
}
