package com.v2ray.ang.ui

import android.content.Intent
import android.net.VpnService
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.v2ray.ang.service.MqttVpnConfig
import com.v2ray.ang.service.MqttVpnService

/**
 * MQTT VPN 配置页：topic/端口等参数 + 启停。
 *
 * 独立于 v2ray 的设置体系（不走 MMKV），用 SharedPreferences("mqtt_vpn")。
 * 通过 action=com.v2ray.ang.MQTT_VPN_CONFIG 可从 adb 打开，方便真机联调：
 *   adb shell am start -a com.v2ray.ang.MQTT_VPN_CONFIG
 */
class MqttConfigActivity : ComponentActivity() {

    private val vpnPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            if (result.resultCode == RESULT_OK) {
                reallyStart()
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    ConfigScreen(
                        onStart = { startVpn() },
                        onStop = { stopVpn() },
                    )
                }
            }
        }
    }

    private fun startVpn() {
        val prepare = VpnService.prepare(this)
        if (prepare != null) {
            vpnPermissionLauncher.launch(prepare)
        } else {
            reallyStart()
        }
    }

    private fun reallyStart() {
        startForegroundService(
            Intent(this, MqttVpnService::class.java).setAction(MqttVpnService.ACTION_START)
        )
    }

    private fun stopVpn() {
        startService(
            Intent(this, MqttVpnService::class.java).setAction(MqttVpnService.ACTION_STOP)
        )
    }

    companion object {
        const val ACTION_OPEN = "com.v2ray.ang.MQTT_VPN_CONFIG"
    }
}

@Composable
private fun ConfigScreen(onStart: () -> Unit, onStop: () -> Unit) {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val cfg = remember { MqttVpnConfig.load(ctx) }

    var topic by remember { mutableStateOf(cfg.topic) }
    var replyTopic by remember { mutableStateOf(cfg.replyTopic) }
    var key by remember { mutableStateOf(cfg.key) }
    var socksPort by remember { mutableStateOf(cfg.socksPort.toString()) }
    var rpcPort by remember { mutableStateOf(cfg.rpcPort.toString()) }
    var heartbeat by remember { mutableStateOf(cfg.heartbeatSec.toString()) }
    var deadTimeout by remember { mutableStateOf(cfg.deadTimeoutSec.toString()) }
    var running by remember { mutableStateOf(MqttVpnService.isRunning) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text("MQTT VPN（socks5_client_mqtt 数据面）", style = MaterialTheme.typography.titleMedium)

        OutlinedTextField(
            value = topic,
            onValueChange = { topic = it },
            label = { Text("request topic（默认 hi，公共 broker 测试可用）") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
        )
        OutlinedTextField(
            value = replyTopic,
            onValueChange = { replyTopic = it },
            label = { Text("reply topic（空 = sys/device/response）") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
        )
        OutlinedTextField(
            value = key,
            onValueChange = { key = it },
            label = { Text("私钥/整数表达式（空 = 不签名）") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedTextField(
                value = socksPort,
                onValueChange = { socksPort = it },
                label = { Text("SOCKS5 端口") },
                modifier = Modifier.weight(1f),
                singleLine = true,
            )
            OutlinedTextField(
                value = rpcPort,
                onValueChange = { rpcPort = it },
                label = { Text("RPC 端口") },
                modifier = Modifier.weight(1f),
                singleLine = true,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedTextField(
                value = heartbeat,
                onValueChange = { heartbeat = it },
                label = { Text("心跳(s)") },
                modifier = Modifier.weight(1f),
                singleLine = true,
            )
            OutlinedTextField(
                value = deadTimeout,
                onValueChange = { deadTimeout = it },
                label = { Text("断连判定(s)") },
                modifier = Modifier.weight(1f),
                singleLine = true,
            )
        }

        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Button(
                onClick = {
                    MqttVpnConfig.save(
                        ctx, topic, replyTopic, key,
                        socksPort.toIntOrNull() ?: 1080,
                        rpcPort.toIntOrNull() ?: 2288,
                        heartbeat.toFloatOrNull() ?: 5f,
                        deadTimeout.toFloatOrNull() ?: 15f,
                    )
                    onStart()
                    running = true
                },
                modifier = Modifier.weight(1f),
            ) { Text("授权并启动") }
            OutlinedButton(
                onClick = {
                    onStop()
                    running = false
                },
                modifier = Modifier.weight(1f),
            ) { Text("停止") }
        }

        Text(
            if (running) "状态：运行中" else "状态：未运行",
            style = MaterialTheme.typography.bodyMedium,
        )
        Text(
            "调试：adb reverse tcp:${rpcPort.toIntOrNull() ?: 2288} tcp:${rpcPort.toIntOrNull() ?: 2288} 后，\n" +
                "curl \"http://127.0.0.1:${rpcPort.toIntOrNull() ?: 2288}/r=sess.net_report()\"\n" +
                "Python 日志：adb logcat -s python.stderr",
            style = MaterialTheme.typography.bodySmall,
        )
    }
}
