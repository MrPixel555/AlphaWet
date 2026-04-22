package com.awmanager.ui

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
        runCatching {
            RuntimeSecurityGuard.enforceRuntimeSecurity(applicationContext)
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
