package com.awmanager.ui

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.core.app.NotificationCompat
import java.util.concurrent.Executors

class AlphaWetVpnService : VpnService() {
    companion object {
        const val ACTION_START = "alphawet.action.START"
        const val ACTION_STOP = "alphawet.action.STOP"
        private const val NOTIFICATION_CHANNEL_ID = "alphawet_vpn"
        private const val NOTIFICATION_ID = 2380
    }

    private val executor = Executors.newSingleThreadExecutor()

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                executor.execute {
                    stopRuntime()
                }
                return START_NOT_STICKY
            }

            ACTION_START -> {
                startForegroundCompat(buildNotification("Starting AlphaWet device tunnel..."))
                val workIntent = Intent(intent)
                executor.execute {
                    startRuntime(workIntent, startId)
                }
                return START_STICKY
            }
        }
        return START_STICKY
    }

    private fun startRuntime(intent: Intent, startId: Int) {
        try {
            val bundle = RuntimeBundleFactory.fromIntent(this, intent)
            val tunFd = establishTunFd()
            if (tunFd < 0) {
                XrayCoreRuntimeManager.recordFailure(
                    message = "Failed to establish the AlphaWet VPN interface.",
                    logFile = bundle.logFile,
                )
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelfResult(startId)
                return
            }

            val result = XrayCoreRuntimeManager.start(bundle = bundle, tunFd = tunFd)
            runCatching {
                ParcelFileDescriptor.adoptFd(tunFd).close()
            }

            if (result["success"] == true) {
                val label = bundle.displayName.ifBlank { "AlphaWet" }
                val text = "AlphaWet is tunneling the whole device through $label."
                val manager = getSystemService(NotificationManager::class.java)
                manager.notify(NOTIFICATION_ID, buildNotification(text))
            } else {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelfResult(startId)
            }
        } catch (error: Throwable) {
            XrayCoreRuntimeManager.recordFailure(
                message = error.message ?: error.javaClass.simpleName,
                logFile = null,
            )
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelfResult(startId)
        }
    }

    private fun stopRuntime() {
        XrayCoreRuntimeManager.stop("device-vpn")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun establishTunFd(): Int {
        val builder = Builder()
            .setSession("AlphaWet")
            .setMtu(1500)
            .addAddress("172.19.0.1", 30)
            .addAddress("fdfe:dcba:9876::1", 126)
            .addRoute("0.0.0.0", 0)
            .addRoute("::", 0)
            .addDnsServer("1.1.1.1")
            .addDnsServer("8.8.8.8")

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        if (launchIntent != null) {
            val pendingIntent = PendingIntent.getActivity(
                this,
                0,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            builder.setConfigureIntent(pendingIntent)
        }

        runCatching {
            builder.addDisallowedApplication(packageName)
        }

        val vpnInterface = builder.establish() ?: return -1
        return vpnInterface.detachFd()
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(text: String): Notification {
        ensureNotificationChannel()
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle("AlphaWet")
            .setContentText(text)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(pendingIntent)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(NOTIFICATION_CHANNEL_ID) != null) {
            return
        }
        manager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "AlphaWet VPN",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Foreground notification for the AlphaWet device tunnel"
            },
        )
    }

    override fun onDestroy() {
        super.onDestroy()
        executor.shutdownNow()
    }
}
