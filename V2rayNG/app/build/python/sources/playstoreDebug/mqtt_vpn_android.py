"""socks5_client_mqtt 的 Android/Chaquopy 启动器（由 MqttVpnService 调用）。

职责只有一个：把 Kotlin 传来的配置 dict 拼成 CLI argv，调用
client.socks5_client_mqtt.main() 的原始入口——远端出口/心跳/NACK 重传/
broker 竞速等全部逻辑零改动复用；另暴露 request_stop()/status() 供
服务侧停机与查询。stdout/stderr 由 Chaquopy 自动重定向到 logcat
（tag: python.stdout / python.stderr）。

用法（Kotlin 侧）：
    val mod = Python.getInstance().getModule("mqtt_vpn_android")
    thread { mod.callAttr("start", cfgDict).toInt() }   // 阻塞直到会话结束
    mod.callAttr("request_stop")                        // 关会话 -> start 返回
"""
from __future__ import annotations

import sys
import threading

_lock = threading.Lock()
_state = {"running": False, "rc": None, "sess": None, "transport": None, "argv": None}


def _build_argv(cfg: dict) -> list:
    cfg = cfg or {}
    argv = []

    def add(flag, val):
        # 空值跳过：让 socks5_client_mqtt 走自己的默认值
        if val is None or val == "":
            return
        argv.extend([flag, str(val)])

    add("--request-topic", cfg.get("topic"))
    add("--reply-topic", cfg.get("reply_topic"))
    add("--private-key", cfg.get("key"))
    add("--host", cfg.get("socks_host"))
    add("--port", cfg.get("socks_port"))
    add("--rpc-host", cfg.get("rpc_host"))
    add("--rpc-port", cfg.get("rpc_port"))
    add("--heartbeat", cfg.get("heartbeat"))
    add("--dead-timeout", cfg.get("dead_timeout"))
    add("--ttl", cfg.get("ttl"))
    add("--connect-timeout", cfg.get("connect_timeout"))
    add("--frame-max", cfg.get("frame_max"))
    add("--gap-timeout", cfg.get("gap_timeout"))
    add("--timeout", cfg.get("timeout"))
    return argv


def _install_session_trace():
    """给 RemoteSocks5 包一层壳，把实例登记进 _state 供 request_stop() 关闭。

    main() 内部构造 RemoteSocks5(transport, ...)，改其源码不划算；
    只在类上套一层子类并替换模块属性，实例化时顺手记录 self/transport。
    """
    import client.socks5_client_mqtt as s5

    if getattr(s5.RemoteSocks5, "_mqtt_vpn_traced", False):
        return

    class _Traced(s5.RemoteSocks5):
        _mqtt_vpn_traced = True

        def __init__(self, *a, **ka):
            super().__init__(*a, **ka)
            with _lock:
                _state["sess"] = self
                if a:
                    _state["transport"] = a[0]

    s5.RemoteSocks5 = _Traced


def start(cfg: dict) -> int:
    """阻塞运行直到会话结束；必须在服务的工作线程里调用。"""
    import client.socks5_client_mqtt as s5

    with _lock:
        _state.update(running=True, rc=None, sess=None, transport=None)
    _install_session_trace()
    argv = _build_argv(cfg)
    _state["argv"] = argv
    sys.stderr.write("[mqtt_vpn] start argv=%r\n" % (argv,))
    sys.stderr.flush()
    try:
        rc = s5.main(argv)
    except BaseException as exc:  # 服务线程里异常不能无声消失
        sys.stderr.write("[mqtt_vpn] main 异常: %r\n" % (exc,))
        sys.stderr.flush()
        rc = -1
    with _lock:
        _state.update(running=False, rc=rc)
    sys.stderr.write("[mqtt_vpn] 会话结束 rc=%r\n" % rc)
    sys.stderr.flush()
    return rc


def request_stop():
    """请求结束：关闭会话，main() 的 wait_end 循环随即返回。"""
    with _lock:
        sess = _state.get("sess")
    if sess is None:
        return False
    try:
        sess.close()
    except Exception as exc:
        sys.stderr.write("[mqtt_vpn] close 异常: %r\n" % (exc,))
        sys.stderr.flush()
        return False
    return True


def status() -> dict:
    with _lock:
        return {k: v for k, v in _state.items() if k != "sess"}
