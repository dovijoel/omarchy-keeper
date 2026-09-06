"""Keeper Commander kept warm in memory, answering over a private unix socket.

Every `keeper` CLI invocation logs in and syncs the whole vault (about 8 s on
a 1400-record vault). This process does that once, then serves Commander
commands in a few milliseconds until it has been idle for a while.

Protocol: one JSON object per connection, newline-terminated.
  {"op": "run", "args": ["clipboard-copy", "<uid>", "--output", "stdout"]}
  {"op": "ping"}   {"op": "quit"}
Reply: {"ok": bool, "output": str, "error": str}

Run through bin/omarchy-keeper-daemon, which picks the interpreter of the
installed Commander and passes the config path, socket path and idle timeout.
"""

import contextlib
import io
import json
import logging
import os
import shlex
import socket
import sys
import time


def main():
    if len(sys.argv) != 4:
        print("usage: omarchy-keeper-daemon.py <commander-config.json> <socket> <idle-seconds>", file=sys.stderr)
        return 2
    config_path, sock_path, idle_seconds = sys.argv[1], sys.argv[2], int(sys.argv[3])

    logging.basicConfig(level=logging.WARNING, stream=sys.stderr, format="%(asctime)s %(levelname)s %(message)s")

    from keepercommander import cli
    from keepercommander.__main__ import get_params_from_config

    params = get_params_from_config(config_path)
    params.batch_mode = True

    def run(args):
        if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
            return {"ok": False, "output": "", "error": "args must be a list of strings"}
        out, err = io.StringIO(), io.StringIO()
        handler = logging.StreamHandler(err)
        handler.setLevel(logging.WARNING)
        root = logging.getLogger()
        root.addHandler(handler)
        ok = True
        try:
            with contextlib.redirect_stdout(out):
                result = cli.do_command(params, shlex.join(args))
            if result:
                out.write(str(result))
                out.write("\n")
        except Exception as exc:  # noqa: BLE001 - surfaced to the caller
            ok = False
            err.write(f"{type(exc).__name__}: {exc}\n")
        finally:
            root.removeHandler(handler)
        if not params.session_token:
            ok = False
            err.write("not logged in\n")
        return {"ok": ok, "output": out.getvalue(), "error": err.getvalue()}

    # Warm up: this is the slow login + full sync every CLI call would pay.
    warm = run(["sync-down"])
    if not warm["ok"]:
        logging.error("warm-up failed: %s", warm["error"].strip())
        return 1

    old_umask = os.umask(0o077)
    try:
        if os.path.exists(sock_path):
            os.unlink(sock_path)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(sock_path)
    finally:
        os.umask(old_umask)
    server.listen(8)
    server.settimeout(5.0)
    last_activity = time.time()

    try:
        while True:
            try:
                conn, _ = server.accept()
            except socket.timeout:
                if time.time() - last_activity > idle_seconds:
                    break
                continue
            last_activity = time.time()
            with conn:
                conn.settimeout(10.0)
                data = b""
                while not data.endswith(b"\n"):
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                try:
                    request = json.loads(data.decode("utf-8") or "{}")
                except ValueError:
                    request = None
                if not isinstance(request, dict):
                    response = {"ok": False, "output": "", "error": "bad request"}
                    quit_after = False
                else:
                    op = request.get("op")
                    quit_after = op == "quit"
                    if op == "ping":
                        response = {"ok": True, "output": "pong", "error": ""}
                    elif op == "quit":
                        response = {"ok": True, "output": "bye", "error": ""}
                    elif op == "run":
                        response = run(request.get("args", []))
                    else:
                        response = {"ok": False, "output": "", "error": "unknown op"}
                try:
                    conn.sendall(json.dumps(response).encode("utf-8") + b"\n")
                except OSError:
                    pass
                if quit_after:
                    break
    finally:
        server.close()
        with contextlib.suppress(OSError):
            os.unlink(sock_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
