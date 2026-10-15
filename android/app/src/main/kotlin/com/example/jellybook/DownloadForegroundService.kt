package com.KaraWilson.JellyBook

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/** Foreground process priority and wake locks while DownloadQueue is active.
 *  The actual download continues in the existing Flutter isolate.
 */
class DownloadForegroundService : Service() {
    private var cpuLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "JellyBook downloads", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val launch = Intent(this, MainActivity::class.java)
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        val openApp = PendingIntent.getActivity(this, 0, launch, pendingFlags)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("JellyBook downloads")
            .setContentText("Downloading volumes for offline reading")
            .setContentIntent(openApp)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        if (cpuLock == null) {
            val power = getSystemService(POWER_SERVICE) as PowerManager
            cpuLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "JellyBook:downloads").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (wifiLock == null) {
            try {
                val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
                @Suppress("DEPRECATION")
                wifiLock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "JellyBook:downloads")
                    .apply { setReferenceCounted(false); acquire() }
            } catch (_: Exception) {
                // Cellular and Wi-Fi transfers still work without a Wi-Fi lock.
            }
        }
        // Never restart a service without the Flutter download queue that owns it.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (wifiLock?.isHeld == true) wifiLock?.release()
        wifiLock = null
        if (cpuLock?.isHeld == true) cpuLock?.release()
        cpuLock = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "jellybook_downloads"
        private const val NOTIFICATION_ID = 7812
    }
}
