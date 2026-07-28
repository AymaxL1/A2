#!/usr/bin/env python3
# =============================================================================
# fake-mihomo.py —— 测试替身(TEST DOUBLE),**不是**真 mihomo 内核。
# =============================================================================
# 用途(PROJECT_AA 06 票):在整晚不碰真系统、不下载真 mihomo 的前提下,给 ProcessPort/HTTPPort
# 提供一个「像 mihomo 一样能被拉起/杀掉、并在 localhost 暴露 REST 子集」的真子进程,用来跑 E2E:
#   * 作为子进程运行(可被宿主 ProcessPort 拉起,可被 kill/SIGKILL 回收)——验证「随宿主启停 + 反孤儿」。
#   * 监听一个 localhost 端口(由 --port 指定),暴露 mihomo external-controller 的 REST 子集:
#       GET /version  → {"version": ..., "meta": true}
#       GET /configs  → {"mode": "rule", "mixed-port": 7890, ...}
#       GET /proxies  → 一个分组带当前选中节点 now=STUB-NODE
#
# ⚠️ 这是**测试资产**,故意伪造固定数据、不做任何真实代理/网络行为。
#    真 mihomo 内核的锁版入库(版本号记录在案、随宿主启停)是**用户决策**,留用户;本文件只证明
#    「宿主拉起内核 → REST 读状态 → 内核死亡检测 → 宿主退出回收无孤儿」这套机制成立。
# =============================================================================

import argparse
import json
import signal
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

# 伪造的固定内核状态(测试断言据此对齐)。
FAKE_VERSION = "fake-mihomo-0.1 (TEST DOUBLE, NOT real mihomo)"
FAKE_MIXED_PORT = 7890
FAKE_MODE = "rule"
FAKE_NODE = "STUB-NODE"

RESPONSES = {
    "/version": {"version": FAKE_VERSION, "meta": True},
    "/configs": {
        "mode": FAKE_MODE,
        "mixed-port": FAKE_MIXED_PORT,
        "port": 0,
        "socks-port": 0,
        "allow-lan": False,
    },
    "/proxies": {
        "proxies": {
            "GLOBAL": {"type": "Selector", "now": "", "all": ["PROXY", "DIRECT"]},
            "PROXY": {"type": "Selector", "now": FAKE_NODE, "all": [FAKE_NODE, "DIRECT"]},
            "DIRECT": {"type": "Direct"},
        }
    },
}


class Handler(BaseHTTPRequestHandler):
    # 静默:不把每条请求打到 stderr(否则污染宿主日志)。
    def log_message(self, *args):  # noqa: D401
        pass

    def do_GET(self):
        # 只取路径部分(忽略 query)。
        path = self.path.split("?", 1)[0]
        payload = RESPONSES.get(path)
        if payload is None:
            self.send_response(404)
            self.end_headers()
            return
        body = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser(description="fake mihomo REST stub (TEST DOUBLE)")
    parser.add_argument("--port", type=int, required=True, help="localhost REST 端口")
    parser.add_argument("--host", default="127.0.0.1", help="绑定主机(默认 127.0.0.1,仅本机)")
    parser.add_argument("--ignore-sigterm", action="store_true",
                        help="测试:装 handler 吞掉 SIGTERM(模拟不理会优雅终止的内核,验证宿主 SIGKILL 兜底回收)")
    args = parser.parse_args()

    server = HTTPServer((args.host, args.port), Handler)

    # 收到 SIGTERM(宿主优雅回收路径)即干净退出;SIGKILL(强制回收)不可捕获,由内核直接终止。
    def _graceful(_signum, _frame):
        try:
            server.server_close()
        finally:
            sys.exit(0)

    if args.ignore_sigterm:
        # 故意吞掉 SIGTERM:模拟"不理会优雅终止"的内核。它只会被宿主的 SIGKILL 兜底回收——这正是反孤儿必须证明的路径。
        signal.signal(signal.SIGTERM, lambda *_: None)
    else:
        signal.signal(signal.SIGTERM, _graceful)
    signal.signal(signal.SIGINT, _graceful)

    server.serve_forever()


if __name__ == "__main__":
    main()
