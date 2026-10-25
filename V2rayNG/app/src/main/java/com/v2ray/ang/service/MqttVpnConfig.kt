package com.v2ray.ang.service

import android.content.Context

/**
 * MQTT VPN 的可配置参数（SharedPreferences("mqtt_vpn") 存取，配置页写入）。
 *
 * 字段与 socks5_client_mqtt 的 CLI 参数一一对应；空串表示"用脚本默认值"
 * （默认 request/reply topic 为 sys/device/request|response，见 server_mqtt.py）。
 * topic 默认给 "hi"：与现有联调流程一致，公共 broker 上可随意测试。
 */
data class MqttVpnConfig(
    val topic: String,
    val replyTopic: String,
    val key: String,
    val socksPort: Int,
    val rpcPort: Int,
    val heartbeatSec: Float,
    val deadTimeoutSec: Float,
) {
    /** Chaquopy 会把 Java Map 自动转成 Python dict，交给 mqtt_vpn_android.start()。 */
    fun toPythonDict(): Map<String, Any?> = linkedMapOf(
        "topic" to topic,
        "reply_topic" to replyTopic,
        "key" to key,
        "socks_port" to socksPort,
        "rpc_port" to rpcPort,
        "heartbeat" to heartbeatSec,
        "dead_timeout" to deadTimeoutSec,
    )

    companion object {
        fun load(ctx: Context): MqttVpnConfig {
            val sp = ctx.getSharedPreferences("mqtt_vpn", Context.MODE_PRIVATE)
            return MqttVpnConfig(
                topic = sp.getString("topic", "hi")?.trim().orEmpty(),
                replyTopic = sp.getString("reply_topic", "")?.trim().orEmpty(),
                key = sp.getString("key", "")?.trim().orEmpty(),
                socksPort = sp.getInt("socks_port", 1080),
                rpcPort = sp.getInt("rpc_port", 2288),
                heartbeatSec = sp.getFloat("heartbeat", 5f),
                deadTimeoutSec = sp.getFloat("dead_timeout", 15f),
            )
        }

        fun save(
            ctx: Context,
            topic: String,
            replyTopic: String,
            key: String,
            socksPort: Int,
            rpcPort: Int,
            heartbeatSec: Float,
            deadTimeoutSec: Float,
        ) {
            ctx.getSharedPreferences("mqtt_vpn", Context.MODE_PRIVATE)
                .edit()
                .putString("topic", topic.trim())
                .putString("reply_topic", replyTopic.trim())
                .putString("key", key.trim())
                .putInt("socks_port", socksPort)
                .putInt("rpc_port", rpcPort)
                .putFloat("heartbeat", heartbeatSec)
                .putFloat("dead_timeout", deadTimeoutSec)
                .apply()
        }
    }
}
