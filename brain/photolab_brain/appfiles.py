"""The brain's own files. One of the few modules allowed to change files
(see tools/check_mutations_py.sh). Phase 0: only the socket."""

import os
import socket


def prepare_socket_path(path: str) -> None:
    """Create the socket's folder and remove a stale socket left by a crash.
    A socket that still answers belongs to a running brain: refuse."""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    if not os.path.exists(path):
        return
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.settimeout(0.5)
    try:
        probe.connect(path)
    except OSError:
        os.unlink(path)          # nobody listening: stale
        return
    finally:
        probe.close()
    raise RuntimeError(f"E-BRAIN-20 another brain is already listening on {path}")


def remove_socket(path: str) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass
