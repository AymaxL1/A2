# PROTOTYPE — S3 spike 服务端（抛弃式）。三端点回声服务，模拟宿主 UDS/TCP 监听。
import json, os, socket, threading, sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUTSIDE_DIR = os.path.expanduser("~/Library/Application Support/S3Spike")
OUTSIDE_SOCK = os.path.join(OUTSIDE_DIR, "aa.sock")
INSIDE_SOCK = os.path.join(HERE, "workspace", "aa.sock")
TCP_PORT = 8737

def serve(sock, label):
    while True:
        try:
            conn, _ = sock.accept()
        except OSError:
            return
        with conn:
            try:
                conn.recv(4096)
                conn.sendall((json.dumps({"ok": True, "via": label}) + "\n").encode())
            except OSError:
                pass

def uds_listener(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        os.unlink(path)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(path)
    s.listen(8)
    return s

def tcp_listener(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(8)
    return s

listeners = []
for maker, arg, label in [
    (uds_listener, OUTSIDE_SOCK, "uds_outside_workspace"),
    (uds_listener, INSIDE_SOCK, "uds_inside_workspace"),
    (tcp_listener, TCP_PORT, "tcp_localhost"),
]:
    try:
        s = maker(arg)
        listeners.append(s)
        threading.Thread(target=serve, args=(s, label), daemon=True).start()
        print(f"READY {label} {arg}", flush=True)
    except OSError as e:
        print(f"BIND-FAIL {label} {arg} {e}", flush=True)

print("server up; Ctrl-C 退出", flush=True)
try:
    threading.Event().wait()
except KeyboardInterrupt:
    sys.exit(0)
