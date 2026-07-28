#!/usr/bin/env python3
# =============================================================================
# fake-mihomo.py —— 测试替身(TEST DOUBLE),**不是**真 mihomo 内核。
# =============================================================================
# 用途(PROJECT_AA 06/07/08/09 票):在整晚不碰真系统、不下载真 mihomo 的前提下,给 ProcessPort/HTTPPort
# 提供一个「像 mihomo 一样能被拉起/杀掉、并在 localhost 暴露 REST 子集」的真子进程,用来跑 E2E:
#   * 作为子进程运行(可被宿主 ProcessPort 拉起,可被 kill/SIGKILL 回收)——验证「随宿主启停 + 反孤儿」。
#   * 监听一个 localhost 端口(由 --port 指定),暴露 mihomo external-controller 的 REST 子集。
#
# 06 票只读子集:
#       GET /version  → {"version": ..., "meta": true}
#       GET /configs  → {"mode": "rule", "mixed-port": 7890, ...}
#       GET /proxies  → 一个分组带当前选中节点 now=STUB-NODE
#
# 09 票升级为**有状态**(内存维护 mode 与各组当前选中节点),新增写/读(动词对齐真 mihomo external-controller):
#       PATCH /configs         body {"mode": ...}       → 改 mode(后续 GET /configs 反映;真核切模式即 PATCH)
#       PUT   /proxies/<group> body {"name": ...}       → 改该组当前选中(后续 GET /proxies 反映;真核选节点即 PUT)
#       GET   /group/<g>/delay?url=&timeout= → 逐节点延迟;**含至少一个超时节点**(SLOW-NODE 从 delay map 缺席),
#                                            验证「超时如实标注」。
#   有状态 = E2E 能「改后读回验证生效」:切模式/选节点后经 GET /configs、/proxies、proxy.status 读回。
#
# ⚠️ 这是**测试资产**,故意伪造固定数据、不做任何真实代理/网络行为。
#    真 mihomo 内核的锁版入库(版本号记录在案、随宿主启停)是**用户决策**,留用户;本文件只证明
#    「宿主拉起内核 → REST 读/写状态 → 内核死亡检测 → 宿主退出回收无孤儿」这套机制成立。
# =============================================================================

import argparse
import json
import signal
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

# 伪造的固定内核状态(测试断言据此对齐)。
FAKE_VERSION = "fake-mihomo-0.1 (TEST DOUBLE, NOT real mihomo)"
FAKE_MIXED_PORT = 7890

# 一个含多节点的 Selector 组(PROXY)作测试配置:三候选,其中 SLOW-NODE 故意「测速超时」(不在 DELAYS 里)。
# GLOBAL 组 now 留空(""),用于验证「空 now 归一为 nil」。DIRECT 为裸节点(无 all,不入 groups.list)。
GROUPS = {
    "DIRECT": {"type": "Direct"},
    "GLOBAL": {"type": "Selector", "all": ["PROXY", "DIRECT"]},
    "PROXY": {"type": "Selector", "all": ["STUB-NODE", "NODE-B", "SLOW-NODE"]},
}

# 各测试节点的固定延迟(ms)。**SLOW-NODE 故意缺席** → 按组测速时其延迟结果缺失 → 被如实标注为 timeout。
DELAYS = {"STUB-NODE": 120, "NODE-B": 340}

# 有状态内存(随进程存活;PUT 改之,GET 读之)。默认 mode=rule;PROXY 默认选中 STUB-NODE,GLOBAL 空 now。
STATE = {
    "mode": "rule",
    "now": {"PROXY": "STUB-NODE", "GLOBAL": ""},
}


def configs_payload():
    return {
        "mode": STATE["mode"],
        "mixed-port": FAKE_MIXED_PORT,
        "port": 0,
        "socks-port": 0,
        "allow-lan": False,
    }


def proxies_payload():
    proxies = {}
    for name, g in GROUPS.items():
        if g["type"] == "Direct":
            proxies[name] = {"type": "Direct"}
        else:
            proxies[name] = {
                "type": g["type"],
                "now": STATE["now"].get(name, ""),
                "all": list(g["all"]),
            }
    return {"proxies": proxies}


def group_delay_payload(group):
    # mihomo 语义:超时/失败节点**不返回其延迟**(从 delay map 缺席)。故只返回该组候选中「可测通」者(在 DELAYS 内)。
    g = GROUPS.get(group)
    if g is None or "all" not in g:
        return None  # 未知组 → 404
    return {name: DELAYS[name] for name in g["all"] if name in DELAYS}


class Handler(BaseHTTPRequestHandler):
    # 静默:不把每条请求打到 stderr(否则污染宿主日志)。
    def log_message(self, *args):  # noqa: D401
        pass

    def _send_json(self, obj, code=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_empty(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _read_json_body(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) if length > 0 else b""
        if not raw:
            return {}
        try:
            return json.loads(raw.decode("utf-8"))
        except Exception:
            return None  # 解析失败 → 调用方按 400 处理

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        segs = [s for s in path.split("/") if s != ""]

        if path == "/version":
            return self._send_json({"version": FAKE_VERSION, "meta": True})
        if path == "/configs":
            return self._send_json(configs_payload())
        if path == "/proxies":
            return self._send_json(proxies_payload())
        # GET /group/<name>/delay
        if len(segs) == 3 and segs[0] == "group" and segs[2] == "delay":
            payload = group_delay_payload(segs[1])
            if payload is None:
                return self._send_empty(404)
            return self._send_json(payload)

        self._send_empty(404)

    def do_PATCH(self):
        # PATCH /configs {"mode": ...} → 切模式(真核约定 PATCH;有状态:后续 GET /configs 反映)。
        path = self.path.split("?", 1)[0]
        data = self._read_json_body()
        if data is None:
            return self._send_empty(400)
        if path == "/configs":
            mode = data.get("mode")
            if isinstance(mode, str) and mode:
                STATE["mode"] = mode
                return self._send_empty(204)  # mihomo 写成功惯例:204 No Content
            return self._send_empty(400)
        self._send_empty(404)

    def do_PUT(self):
        # PUT /proxies/<group> {"name": ...} → 改该组当前选中(真核约定 PUT;有状态:后续 GET /proxies 反映)。
        path = self.path.split("?", 1)[0]
        segs = [s for s in path.split("/") if s != ""]
        data = self._read_json_body()
        if data is None:
            return self._send_empty(400)
        if len(segs) == 2 and segs[0] == "proxies":
            group = segs[1]
            name = data.get("name")
            g = GROUPS.get(group)
            if g is None or "all" not in g:
                return self._send_empty(404)
            if isinstance(name, str) and name:
                STATE["now"][group] = name
                return self._send_empty(204)
            return self._send_empty(400)
        self._send_empty(404)


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
