import json
import os
import socket
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from photolab_brain import PROTOCOL  # noqa: E402
from photolab_brain.server import handle_line, serve  # noqa: E402


def _connect(path, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.connect(path)
            return s
        except OSError:
            s.close()
            time.sleep(0.05)
    raise AssertionError("brain socket never appeared")


def _call(sock, f, obj):
    sock.sendall(json.dumps(obj).encode() + b"\n")
    return json.loads(f.readline())


def test_handle_line_errors():
    assert handle_line(b"nope")["error"]["code"] == "E-BRAIN-2"
    assert handle_line(b'{"method":"ping"}')["error"]["code"] == "E-BRAIN-2"
    assert handle_line(b'{"id":1,"method":"nope"}')["error"]["code"] == "E-BRAIN-1"
    assert handle_line(b'{"id":1,"method":"ping","params":[]}')["error"]["code"] == "E-BRAIN-2"
    ok = handle_line(b'{"id":5,"method":"ping"}')
    assert ok["id"] == 5 and ok["result"]["pong"] is True and ok["result"]["protocol"] == PROTOCOL


def test_serve_ping_and_shutdown():
    d = tempfile.mkdtemp(prefix="plb")
    path = os.path.join(d, "b.sock")
    t = threading.Thread(target=serve, args=(path,), daemon=True)
    t.start()
    s = _connect(path)
    f = s.makefile("r")
    r = _call(s, f, {"id": 1, "method": "ping", "params": {}})
    assert r["id"] == 1 and r["result"]["pong"] is True
    r = _call(s, f, {"id": 2, "method": "shutdown"})
    assert r == {"id": 2, "result": {"ok": True}}
    t.join(timeout=5)
    assert not t.is_alive()
    assert not os.path.exists(path), "socket file left behind"


def test_stale_socket_is_replaced():
    d = tempfile.mkdtemp(prefix="plb")
    path = os.path.join(d, "b.sock")
    stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stale.bind(path)
    stale.close()                      # file exists, nobody listening
    t = threading.Thread(target=serve, args=(path,), daemon=True)
    t.start()
    s = _connect(path)
    f = s.makefile("r")
    assert _call(s, f, {"id": 1, "method": "ping"})["result"]["pong"] is True
    _call(s, f, {"id": 2, "method": "shutdown"})
    t.join(timeout=5)
