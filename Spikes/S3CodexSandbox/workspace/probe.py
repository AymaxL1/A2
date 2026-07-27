# PROTOTYPE — S3 spike 探针（抛弃式）。在被测沙箱内运行，逐端点尝试连接并输出 JSON 行。
import json, os, socket

TARGETS = [
    ("uds_outside_workspace", "unix", os.path.expanduser("~/Library/Application Support/S3Spike/aa.sock")),
    ("uds_inside_workspace", "unix", os.path.join(os.path.dirname(os.path.abspath(__file__)), "aa.sock")),
    ("tcp_localhost", "tcp", ("127.0.0.1", 8737)),
]

for name, kind, addr in TARGETS:
    result = {"target": name}
    try:
        if kind == "unix":
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        else:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(3)
        s.connect(addr)
        s.sendall(b'{"capability":"probe"}\n')
        data = s.recv(4096).decode().strip()
        s.close()
        result["ok"] = True
        result["reply"] = json.loads(data) if data else None
    except OSError as e:
        result["ok"] = False
        result["errno"] = e.errno
        result["error"] = str(e)
    print(json.dumps(result, ensure_ascii=False), flush=True)
