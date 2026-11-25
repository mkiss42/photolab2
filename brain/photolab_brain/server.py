"""Unix-socket JSON-lines server (docs/PROTOCOL.md).

One thread per connection. Methods are plain functions registered in METHODS:
    def method(params: dict) -> dict
Raise ParamError for bad params; anything else becomes E-BRAIN-3.
"""

import argparse
import json
import logging
import os
import platform
import socketserver
import sys
import threading
import time
from typing import Callable, Dict

from . import PROTOCOL, __version__
from .appfiles import prepare_socket_path, remove_socket

log = logging.getLogger("brain")

MAX_LINE = 16 * 1024 * 1024


class ParamError(ValueError):
    pass


class ShutdownRequested(Exception):
    pass


METHODS: Dict[str, Callable[[dict], dict]] = {}


def method(name: str):
    def deco(fn):
        METHODS[name] = fn
        return fn
    return deco


@method("ping")
def _ping(params: dict) -> dict:
    return {"pong": True, "brain_version": __version__, "protocol": PROTOCOL,
            "python": platform.python_version(), "machine": platform.machine()}


@method("shutdown")
def _shutdown(params: dict) -> dict:
    raise ShutdownRequested()


def handle_line(line: bytes) -> dict:
    """One request line -> one response dict. Never raises (except shutdown)."""
    try:
        msg = json.loads(line.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return {"id": None, "error": {"code": "E-BRAIN-2", "message": "not JSON"}}
    if not isinstance(msg, dict) or not isinstance(msg.get("id"), int):
        return {"id": None, "error": {"code": "E-BRAIN-2", "message": "missing integer id"}}
    rid = msg["id"]
    name = msg.get("method")
    params = msg.get("params")
    if params is None:
        params = {}
    fn = METHODS.get(name) if isinstance(name, str) else None
    if fn is None:
        return {"id": rid, "error": {"code": "E-BRAIN-1", "message": f"unknown method: {name}"}}
    if not isinstance(params, dict):
        return {"id": rid, "error": {"code": "E-BRAIN-2", "message": "params must be an object"}}
    try:
        return {"id": rid, "result": fn(params)}
    except ShutdownRequested:
        raise
    except ParamError as e:
        return {"id": rid, "error": {"code": "E-BRAIN-2", "message": str(e)}}
    except Exception as e:  # noqa: BLE001 - report, keep serving
        log.exception("method %s failed", name)
        return {"id": rid, "error": {"code": "E-BRAIN-3", "message": f"{type(e).__name__}: {e}"}}


class _Handler(socketserver.StreamRequestHandler):
    def handle(self):
        while True:
            line = self.rfile.readline(MAX_LINE + 1)
            if not line:
                return
            line = line.strip()
            if not line:
                continue
            try:
                reply = handle_line(line)
            except ShutdownRequested:
                rid = json.loads(line).get("id")
                self._send({"id": rid, "result": {"ok": True}})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                return
            self._send(reply)

    def _send(self, obj: dict):
        self.wfile.write(json.dumps(obj, separators=(",", ":")).encode("utf-8") + b"\n")
        self.wfile.flush()


class BrainServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True


def _watch_parent(pid: int, server: BrainServer):
    """Exit when the app that started us is gone (crash, force quit)."""
    while True:
        time.sleep(2.0)
        if os.getppid() != pid:
            log.info("parent %s gone, shutting down", pid)
            server.shutdown()
            return


def serve(socket_path: str, parent_pid: int = 0) -> None:
    prepare_socket_path(socket_path)
    server = BrainServer(socket_path, _Handler)
    log.info("brain %s listening on %s (python %s, %s)", __version__, socket_path,
             platform.python_version(), platform.machine())
    if parent_pid:
        threading.Thread(target=_watch_parent, args=(parent_pid, server), daemon=True).start()
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        remove_socket(socket_path)
        log.info("brain stopped")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="photolab-brain")
    ap.add_argument("--socket", required=True)
    ap.add_argument("--parent-pid", type=int, default=0)
    args = ap.parse_args(argv)
    logging.basicConfig(stream=sys.stdout, level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        serve(args.socket, args.parent_pid)
    except RuntimeError as e:
        log.error("%s", e)
        return 2
    return 0
