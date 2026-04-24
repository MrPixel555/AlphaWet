package com.awmanager.ui

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.content.pm.ActivityInfo
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val logTag = "AlphaWet"
    }

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
        }.onFailure { error ->
            val reason = error.message ?: error.javaClass.simpleName
            Log.e(logTag, "Startup security check failed: $reason", error)
            showStartupFailureDialog(reason)
            return
        }
        warmUpIntegrityProviderAsync()
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
        call.argument<String>("configJson")?.trim().takeUnless { it.isNullOrEmpty() }
            ?: throw IllegalArgumentException("configJson is required for authentication.")

        try {
            val transientBundle = RuntimeBundleFactory.fromMethodCall(applicationContext, call)
                .copy(enableDeviceVpn = false)
            return XrayCoreRuntimeManager.authenticateViaTransientRuntime(transientBundle) { bundle ->
                securityPolicyEnforcer.performPostConnectPolicy(
                    configId = configId,
                    enableDeviceVpn = false,
                    httpPort = bundle.httpPort,
                )
            }
        } catch (error: Throwable) {
            throw error
        }
    }

    private fun warmUpIntegrityProviderAsync() {
        Thread {
            runCatching {
                securityPolicyEnforcer.warmUpIntegrityProviderIfConfigured()
            }.onFailure { error ->
                Log.w(
                    logTag,
                    "Play Integrity warm-up failed: ${error.message ?: error.javaClass.simpleName}",
                    error,
                )
            }
        }.start()
    }

    private fun showStartupFailureDialog(reason: String) {
        runOnUiThread {
            AlertDialog.Builder(this)
                .setTitle("Startup blocked")
                .setMessage(
                    "AlphaWet could not start because a security check failed.\n\nReason: $reason",
                )
                .setCancelable(false)
                .setPositiveButton("Close") { _, _ ->
                    finishAffinity()
                }
                .show()
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
