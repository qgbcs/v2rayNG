package com.v2ray.ang.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import com.v2ray.ang.BuildConfig
import com.v2ray.ang.R
import com.v2ray.ang.ui.MqttConfigActivity
import com.v2ray.ang.util.LogUtil
import java.net.InetSocketAddress
import java.net.Socket
import kotlin.concurrent.thread

/**
 * MQTT VPN：只借用 v2rayNG 建立 VPN 的流程（VpnService 建 tun + hev tun2socks），
 * 数据面完全不走 v2ray 核心——
 *
 *   app 流量 -> tun(fd) -> hev-socks5-tunnel -> 127.0.0.1:1080
 *            -> Chaquopy 里的 socks5_client_mqtt.py（仅 CONNECT，域名远端解析）
 *            -> 公共 MQTT broker -> 远端 server_mqtt 出口
 *
 * DNS：Python 端 SOCKS5 不支持 UDP，hev 的 mapdns 用 fake-IP（100.64/10）
 * 应答指向 198.18.0.2 的查询，hev 回连 fake-IP 时映射回域名再 socks5h 出去。
 * 调试：HTTP RPC 在 127.0.0.1:2288（adb reverse tcp:2288 tcp:2288 后 curl）。
 */
class MqttVpnService : VpnService() {

    companion object {
        const val ACTION_START = "com.v2ray.ang.mqttvpn.START"
        const val ACTION_STOP = "com.v2ray.ang.mqttvpn.STOP"
        private const val TAG = "MqttVpn"
        private const val CHANNEL_ID = "mqtt_vpn"
        private const val NOTIFICATION_ID = 92
        private const val VPN_IPV4 = "26.26.26.1"
        private const val MAPDNS_IPV4 = "198.18.0.2"
        private const val MTU = 8500

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    private var vpnInterface: ParcelFileDescriptor? = null
    private var hevService: TProxyService? = null

    @Volatile
    private var stopping = false

    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "MQTT VPN", NotificationManager.IMPORTANCE_LOW)
        )
    }

    override fun onRevoke() {
        LogUtil.w(TAG, "VPN 权限被系统撤销")
        stopAll()
    }

    override fun onDestroy() {
        if (!stopping) {
            stopAll()
        }
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification())
        if (intent?.action == ACTION_STOP) {
            stopAll()
            return START_NOT_STICKY
        }
        if (isRunning) {
            return START_STICKY
        }
        // VPN 授权由配置页先行请求（VpnService.prepare），这里只兜底校验。
        if (prepare(this) != null) {
            LogUtil.e(TAG, "VPN 权限未授予，请从 MQTT 配置页启动")
            stopAll()
            return START_NOT_STICKY
        }

        val tun = try {
            Builder()
                .setSession("MQTT VPN")
                .setMtu(MTU)
                .addAddress(VPN_IPV4, 30)
                .addRoute("0.0.0.0", 0)
                .addDnsServer(MAPDNS_IPV4)
                // 自己的包必须豁免：否则连 broker 的 MQTT 连接会被路由进 tun 成环
                .addDisallowedApplication(BuildConfig.APPLICATION_ID)
                .establish()
        } catch (e: Exception) {
            LogUtil.e(TAG, "establish VPN 失败: ${e.message}")
            null
        }
        if (tun == null) {
            stopAll()
            return START_NOT_STICKY
        }
        vpnInterface = tun
        isRunning = true
        stopping = false

        val cfg = MqttVpnConfig.load(this)
        LogUtil.i(TAG, "MQTT VPN 启动: topic=${cfg.topic.ifEmpty { "(默认)" }} socks=127.0.0.1:${cfg.socksPort} rpc=${cfg.rpcPort}")

        // Python 数据面：socks5_client_mqtt.main() 阻塞运行直到会话结束
        thread(name = "mqtt-vpn-python", isDaemon = true) {
            val rc = try {
                if (!Python.isStarted()) {
                    Python.start(AndroidPlatform(applicationContext))
                }
                Python.getInstance()
                    .getModule("mqtt_vpn_android")
                    .callAttr("start", cfg.toPythonDict())
                    .toInt()
            } catch (e: Throwable) {
                LogUtil.e(TAG, "Python 侧异常: ${e.message}")
                -1
            }
            LogUtil.i(TAG, "Python 会话结束 rc=$rc")
            if (!stopping) {
                stopAll() // 服务器死/断连导致会话自然结束 -> 收摊
            }
        }

        // 等 Python 的 SOCKS5 监听就绪（要先连 broker 并打开远端会话）再启 hev
        thread(name = "mqtt-vpn-hev", isDaemon = true) {
            if (!waitTcpReady("127.0.0.1", cfg.socksPort, 60_000)) {
                LogUtil.e(TAG, "等待 SOCKS5 127.0.0.1:${cfg.socksPort} 就绪超时")
                stopAll()
                return@thread
            }
            val tproxy = TProxyService(applicationContext, tun, { isRunning }, {})
            tproxy.startTun2Socks(buildHevYaml(cfg.socksPort))
            hevService = tproxy
            LogUtil.i(TAG, "hev tun2socks 已启动 -> 127.0.0.1:${cfg.socksPort}")
        }
        return START_STICKY
    }

    /** 幂等收摊：hev -> python -> tun -> 前台服务，可从任意线程调用。 */
    private fun stopAll() {
        if (stopping) {
            return
        }
        stopping = true
        isRunning = false

        runCatching { hevService?.stopTun2Socks() }
        hevService = null
        runCatching {
            if (Python.isStarted()) {
                Python.getInstance().getModule("mqtt_vpn_android").callAttr("request_stop")
            }
        }
        runCatching { vpnInterface?.close() }
        vpnInterface = null

        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        LogUtil.i(TAG, "MQTT VPN 已停止")
    }

    private fun buildHevYaml(socksPort: Int): String = buildString {
        appendLine("tunnel:")
        appendLine("  mtu: $MTU")
        appendLine("  ipv4: $VPN_IPV4")
        appendLine("socks5:")
        appendLine("  port: $socksPort")
        appendLine("  address: 127.0.0.1")
        appendLine("  udp: 'udp'")
        appendLine("mapdns:")
        appendLine("  address: $MAPDNS_IPV4")
        appendLine("  port: 53")
        appendLine("  network: 100.64.0.0")
        appendLine("  netmask: 255.192.0.0")
        appendLine("  cache-size: 10000")
        appendLine("misc:")
        appendLine("  log-level: info")
        appendLine("  tcp-read-write-timeout: 300000")
        appendLine("  udp-read-write-timeout: 60000")
    }

    private fun waitTcpReady(host: String, port: Int, timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline && !stopping) {
            try {
                Socket().use { s ->
                    s.connect(InetSocketAddress(host, port), 400)
                    return true
                }
            } catch (_: Exception) {
                Thread.sleep(300)
            }
        }
        return false
    }

    private fun buildNotification(): Notification {
        val contentPi = PendingIntent.getActivity(
            this, 0,
            Intent(this, MqttConfigActivity::class.java).setAction(MqttConfigActivity.ACTION_OPEN),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stopPi = PendingIntent.getService(
            this, 1,
            Intent(this, MqttVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_name)
            .setContentTitle("MQTT VPN")
            .setContentText("socks5_client_mqtt 数据面运行中")
            .setContentIntent(contentPi)
            .addAction(0, "停止", stopPi)
            .setOngoing(true)
            .build()
    }
}
