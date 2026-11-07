#!/usr/bin/env python3
"""The Mac end of the app's harness link (HarnessLink.swift, Debug builds): no devicectl.

Advertises _handsy-harness._tcp over Bonjour; the app connects and streams its log, which lands in
$LIVE/debug.log (the same lines as Documents/debug.log). Commands for the app: drop a JSON array of launch
arguments into $LIVE/outbox/ (harness/lib.sh does). Screenshots the app sends go to /tmp/harness-shots/.
$LIVE/connected exists while the app is connected. Run it in the background: harness/live.py &
"""
import base64, json, os, socket, subprocess, sys, threading, time

LIVE = os.environ.get("HARNESS_LIVE", "/tmp/harness-live")
PORT = int(os.environ.get("HARNESS_LIVE_PORT", "7290"))
os.makedirs(f"{LIVE}/outbox", exist_ok=True)
os.makedirs("/tmp/harness-shots", exist_ok=True)
flag = f"{LIVE}/connected"


def serve(conn):
    open(flag, "w").write(time.strftime("%Y-%m-%dT%H:%M:%S\n"))
    stop = threading.Event()

    def outbox():  # commands for the app, oldest first
        while not stop.is_set():
            for name in sorted(os.listdir(f"{LIVE}/outbox")):
                path = f"{LIVE}/outbox/{name}"
                try:
                    args = json.load(open(path))
                    conn.sendall((json.dumps(args) + "\n").encode())
                except (OSError, ValueError):
                    pass
                os.remove(path)
            time.sleep(0.2)

    threading.Thread(target=outbox, daemon=True).start()
    log = open(f"{LIVE}/debug.log", "a", buffering=1)
    for raw in conn.makefile("rb"):
        line = raw.decode("utf-8", "replace").rstrip("\n")
        if line.startswith("L "):
            log.write(line[2:] + "\n")
        elif line.startswith("F "):
            _, name, data = line.split(" ", 2)
            with open("/tmp/" + os.path.normpath(name).lstrip("./"), "wb") as f:
                f.write(base64.b64decode(data))
    stop.set()
    os.path.exists(flag) and os.remove(flag)


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", PORT))
    srv.listen(1)
    adv = subprocess.Popen(["dns-sd", "-R", "handsy-harness", "_handsy-harness._tcp", "local", str(PORT)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"harness live: listening on :{PORT}, log {LIVE}/debug.log", flush=True)
    try:
        while True:
            conn, addr = srv.accept()
            print(f"harness live: app connected from {addr[0]}", flush=True)
            try:
                serve(conn)
            except OSError:
                pass
            print("harness live: app disconnected", flush=True)
    finally:
        adv.terminate()
        os.path.exists(flag) and os.remove(flag)


if __name__ == "__main__":
    sys.exit(main())
