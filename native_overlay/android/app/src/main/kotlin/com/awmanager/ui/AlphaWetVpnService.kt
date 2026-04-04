package com.awmanager.ui

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

class AlphaWetVpnService : VpnService() {
    companion object {
        private const val ACTION_START = "com.alphacraft.alphawet.action.START_VPN"
        private const val ACTION_STOP = "com.alphacraft.alphawet.action.STOP_VPN"
        private const val EXTRA_CONFIG_ID = "configId"
        private const val NOTIFICATION_CHANNEL_ID = "alphawet_vpn_runtime"
        private const val NOTIFICATION_ID = 41021
        private val lock = Object()
        private var pendingBundle: RuntimeBundle? = null
        private var pendingResult: Map<String, Any?>? = null

        fun requestStart(context: Context, bundle: RuntimeBundle): Map<String, Any?> {
            synchronized(lock) {
                pendingBundle = bundle
                pendingResult = null
            }
            val intent = Intent(context, AlphaWetVpnService::class.java).apply {
                action = ACTION_START
            }
            ContextCompat.startForegroundService(context, intent)
            return waitForPendingResult(timeoutMs = 15000L)
        }

        fun requestStop(context: Context, configId: String): Map<String, Any?> {
            synchronized(lock) {
                pendingResult = null
            }
            val intent = Intent(context, AlphaWetVpnService::class.java).apply {
                action = ACTION_STOP
                putExtra(EXTRA_CONFIG_ID, configId)
            }
            context.startService(intent)
            return waitForPendingResult(timeoutMs = 8000L) + mapOf("configId" to configId)
        }

        private fun takePendingBundle(): RuntimeBundle? = synchronized(lock) {
            val bundle = pendingBundle
            pendingBundle = null
            bundle
        }

        private fun publishPendingResult(result: Map<String, Any?>) {
            synchronized(lock) {
                pendingResult = result
                lock.notifyAll()
            }
        }

        private fun waitForPendingResult(timeoutMs: Long): Map<String, Any?> {
            val deadline = System.currentTimeMillis() + timeoutMs
            synchronized(lock) {
                while (pendingResult == null && System.currentTimeMillis() < deadline) {
                    lock.wait(deadline - System.currentTimeMillis())
                }
                return pendingResult ?: mapOf(
                    "state" to "error",
                    "success" to false,
                    "message" to "Timed out while waiting for the Android VPN service.",
                )
            }
        }
    }

    private var tunnelFd: Int = -1

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                val configId = intent.getStringExtra(EXTRA_CONFIG_ID) ?: "unknown"
                val result = stopRuntime(configId)
                publishPendingResult(result)
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                startForegroundCompat()
                val bundle = takePendingBundle()
                if (bundle == null) {
                    val result = mapOf(
                        "state" to "error",
                        "success" to false,
                        "message" to "No pending runtime bundle was available for the VPN service.",
                    )
                    publishPendingResult(result)
                    stopSelf()
                    return START_NOT_STICKY
                }
                val result = startRuntime(bundle)
                publishPendingResult(result)
                if (result["success"] != true) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                return START_STICKY
            }
        }
    }

    override fun onRevoke() {
        stopRuntime(XrayCoreRuntimeManager.status()["configId"]?.toString() ?: "unknown")
        super.onRevoke()
    }

    override fun onDestroy() {
        closeTunnelFd()
        super.onDestroy()
    }

    private fun startRuntime(bundle: RuntimeBundle): Map<String, Any?> {
        closeTunnelFd()
        val tunInterface = buildVpnInterface() ?: return mapOf(
            "state" to "error",
            "success" to false,
            "message" to "Android VPN service could not establish the tunnel interface.",
        )
        tunnelFd = tunInterface.detachFd()
        return XrayCoreRuntimeManager.start(bundle, tunFd = tunnelFd)
    }

    private fun stopRuntime(configId: String): Map<String, Any?> {
        val result = XrayCoreRuntimeManager.stop(configId)
        closeTunnelFd()
        stopForegroundCompat()
        return result
    }

    private fun buildVpnInterface(): ParcelFileDescriptor? {
        return Builder()
            .setSession("AlphaWet")
            .setMtu(1500)
            .addAddress("10.31.0.1", 30)
            .addRoute("0.0.0.0", 0)
            .addAddress("fdfe:dcba:9876::1", 126)
            .addRoute("::", 0)
            .addDnsServer("1.1.1.1")
            .addDnsServer("8.8.8.8")
            .apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    setMetered(false)
                }
                runCatching { addDisallowedApplication(packageName) }
            }
            .establish()
    }

    private fun closeTunnelFd() {
        if (tunnelFd < 0) {
            return
        }
        runCatching {
            ParcelFileDescriptor.adoptFd(tunnelFd).close()
        }
        tunnelFd = -1
    }

    private fun startForegroundCompat() {
        createNotificationChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification)
        } else {
            @Suppress("DEPRECATION")
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName) ?: Intent()
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("AlphaWet is running")
            .setContentText("Full-device tunnel is active for the selected profile.")
            .setSmallIcon(android.R.drawable.presence_online)
            .setOnlyAlertOnce(true)
            .setContentIntent(pendingIntent)
            .build()
            .apply {
                flags = flags or Notification.FLAG_ONGOING_EVENT
            }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            "AlphaWet VPN Runtime",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shows the active AlphaWet device tunnel status."
        }
        manager.createNotificationChannel(channel)
    }
}
