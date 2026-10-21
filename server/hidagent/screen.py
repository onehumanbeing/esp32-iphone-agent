"""The phone's screen, received over AirPlay mirroring by UxPlay, as JPEG frames."""

import asyncio
import logging
import os
import signal
import socket
import subprocess
import threading
import time
from pathlib import Path

log = logging.getLogger(__name__)


class Screen:
    """The latest JPEG frame of the phone's screen, from UxPlay.

    By default the server runs UxPlay itself and reads frames from a pipe. With `stream` ("host:port") it follows
    a standalone receiver instead (`python -m hidagent.receiver`), so restarting the server does not end the
    phone's Screen Mirroring session. `pidfile` is where UxPlay's pid is recorded, so a server following a
    receiver can restart that receiver's UxPlay.
    """

    def __init__(self, name: str = "iPhone Agent", fps: int = 8, quality: int = 75,
                 stream: str | None = None, pidfile: Path | None = None):
        if stream and not stream.rpartition(":")[2].isdigit():
            raise ValueError(f"MIRROR_STREAM must be host:port, not {stream!r}")
        self.name, self.fps, self.quality = name, fps, quality
        self.stream, self.pidfile = stream, pidfile
        self.frame: bytes | None = None
        self.updated = 0.0
        self._proc = None
        self._sock = None
        self._clients_at, self._clients_n = 0.0, None
        self._stopping = False

    def start(self) -> None:
        self._thread = threading.Thread(target=self._follow if self.stream else self._supervise, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stopping = True
        if self._proc:
            self._proc.terminate()
        sock = self._sock
        if sock:
            try:
                sock.shutdown(socket.SHUT_RDWR)  # wakes the follower's recv(); close() alone does not on Linux
            except OSError:
                pass

    def restart(self) -> None:
        """Restart UxPlay (its supervisor starts a new one); the phone must choose it in Screen Mirroring again."""
        log.warning("AirPlay receiver: no new frames, restarting it")
        self.frame, self.updated = None, 0.0  # nothing since the restart: the next action must not restart it again
        if self.stream:
            if self._sock is None:  # the receiver is gone, so its pid may belong to an unrelated process by now
                log.warning("no AirPlay receiver is streaming at %s: start `python -m hidagent.receiver`", self.stream)
                return
            try:
                os.kill(int(Path(self.pidfile).read_text()), signal.SIGTERM)
            except (OSError, TypeError, ValueError) as e:
                log.warning("could not restart the standalone receiver: %r", e)
        elif self._proc and self._proc.poll() is None:
            self._proc.terminate()

    def _follow(self) -> None:
        """Read frames from the standalone receiver's TCP stream; reconnect whenever it goes away."""
        host, port = self.stream.rsplit(":", 1)
        waiting = False
        while not self._stopping:
            try:
                with socket.create_connection((host, int(port)), timeout=2) as sock:
                    sock.settimeout(None)
                    self._sock, waiting = sock, False
                    log.info("following the AirPlay receiver at %s", self.stream)
                    self._consume(lambda: sock.recv(1 << 16))
            except OSError:
                if not waiting:
                    log.info("waiting for the AirPlay receiver at %s (python -m hidagent.receiver)", self.stream)
                    waiting = True
            finally:
                self._sock, self.frame = None, None
            time.sleep(0.5)

    def _supervise(self) -> None:
        """Keep UxPlay running: it exits on some disconnects, so restart it every time."""
        while not self._stopping:
            if os.name == "nt":
                self._run_with_socket()
            else:
                read_fd, write_fd = os.pipe()
                self._launch(f"fdsink fd={write_fd}", pass_fds=(write_fd,))
                os.close(write_fd)
                self._read(read_fd)  # returns when UxPlay closes the pipe
            code = self._proc.wait()
            self.frame = None
            log.warning("AirPlay receiver exited (code %s), restarting", code)
            time.sleep(1)

    def _launch(self, sink: str, **popen) -> None:
        sink = (f"videorate drop-only=true ! video/x-raw,framerate={self.fps}/1 ! "
                f"jpegenc quality={self.quality} ! {sink}")
        uxplay = os.environ.get("UXPLAY", "uxplay")  # e.g. C:/msys64/ucrt64/bin/uxplay.exe
        self._proc = subprocess.Popen([uxplay, "-n", self.name, "-nh", "-a", "-reset", "0", "-vs", sink],
                                      **popen)  # UxPlay logs to stdout: keep them in ours
        if self.pidfile:
            Path(self.pidfile).write_text(str(self._proc.pid))
        log.info("AirPlay receiver '%s' started (pid %d)", self.name, self._proc.pid)

    def _run_with_socket(self) -> None:
        """Windows cannot hand UxPlay a pipe, so its pipeline connects back to a local socket instead."""
        with socket.create_server(("127.0.0.1", 0)) as srv:
            srv.settimeout(0.5)
            self._launch(f"tcpclientsink host=127.0.0.1 port={srv.getsockname()[1]}")
            while self._proc.poll() is None:  # the pipeline reconnects whenever UxPlay rebuilds it
                try:
                    conn, _ = srv.accept()
                except TimeoutError:
                    continue
                with conn:
                    conn.settimeout(None)
                    try:
                        self._consume(lambda c=conn: c.recv(1 << 16))
                    except OSError:
                        pass  # UxPlay went away mid-frame

    @property
    def live(self) -> bool:
        running = self._sock is not None if self.stream else self._proc is not None and self._proc.poll() is None
        if not running or self.frame is None:
            return False
        clients = None if self.stream else self._clients()  # a followed receiver's process is not ours
        if clients is not None:  # Linux: is a phone connected to UxPlay right now?
            return clients > 0
        return time.time() - self.updated < 90  # elsewhere: AirPlay sends no frames while the screen is still

    def _clients(self) -> int | None:
        """Established TCP connections of the UxPlay process (a mirroring phone keeps some open).

        Read from /proc, cached for a second; None where /proc is not available (e.g. macOS).
        """
        if time.time() - self._clients_at < 1:
            return self._clients_n
        try:
            fds = os.listdir(f"/proc/{self._proc.pid}/fd")
            inodes = set()
            for fd in fds:
                link = os.readlink(f"/proc/{self._proc.pid}/fd/{fd}")
                if link.startswith("socket:["):
                    inodes.add(link[8:-1])
            n = 0
            for table in ("/proc/net/tcp", "/proc/net/tcp6"):
                with open(table) as f:
                    for row in f.readlines()[1:]:
                        cols = row.split()
                        n += cols[3] == "01" and cols[9] in inodes  # 01 = ESTABLISHED
        except OSError:
            n = None
        self._clients_at, self._clients_n = time.time(), n
        return n

    @property
    def aspect(self) -> float:
        """Frame width / height, read from the JPEG header (portrait iPhone as a fallback)."""
        f = self.frame or b""
        i = f.find(b"\xff\xc0")  # baseline start-of-frame: ... height(2) width(2)
        if i < 0 or len(f) < i + 9:
            return 9 / 19.5
        return int.from_bytes(f[i + 7:i + 9], "big") / int.from_bytes(f[i + 5:i + 7], "big")

    async def settled(self, quiet: float = 0.35, least: float = 0.25, most: float = 4) -> None:
        """Wait until the screen stops changing (AirPlay only sends frames on change)."""
        started = time.time()
        await asyncio.sleep(least)
        while time.time() - self.updated < quiet and time.time() - started < most:
            await asyncio.sleep(0.1)

    async def fresh(self, since: float, timeout: float = 0.8) -> bytes | None:
        """The first frame received after `since`, or None if none arrives in time."""
        deadline = time.time() + timeout
        while self.updated <= since:
            if time.time() > deadline:
                return None
            await asyncio.sleep(0.02)
        return self.frame

    def _read(self, fd: int) -> None:
        with os.fdopen(fd, "rb", buffering=0) as pipe:
            self._consume(lambda: pipe.read(1 << 16))

    def _consume(self, read) -> None:
        """Split a byte stream into JPEG frames (start/end markers) until `read` returns nothing."""
        buf = b""
        while chunk := read():
            buf += chunk
            while (start := buf.find(b"\xff\xd8")) >= 0 and (end := buf.find(b"\xff\xd9", start)) >= 0:
                self.frame, self.updated = buf[start:end + 2], time.time()
                buf = buf[end + 2:]
