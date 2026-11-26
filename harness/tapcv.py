# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow"]
# ///
"""Tap the test iPhone where you mean, without mirroring: screenshot, find the pointer, correct, click, check.

The board's mouse is relative, so a tap is closed-loop: the pointer starts in the top-left corner (`home`), moves by
the calibrated units, and a screenshot shows where it landed (the pointer is a grey disc; it is found as the change
against the shot before the move). Off by more than TOL px: move the difference and look again. Then click, and
check the screen changed (and, with --expect, that the text appeared).

Screenshots come from $HARNESS_SHOT (a command taking an output path; default `iphone-dvtshot`, the developer
service: works with or without Screen Mirroring). Text needs $HARNESS_OCR (a command printing
[{"text","x","y","w","h"}] in image pixels for an image path).

  uv run harness/tapcv.py shot [out.png]
  uv run harness/tapcv.py tap X Y [--expect TEXT]          X Y in screenshot pixels
  uv run harness/tapcv.py tap-text TEXT [--expect TEXT]
  uv run harness/tapcv.py mirror BOARD [--restart]         Control Center > Screen Mirroring > BOARD, until connected
"""
import json, os, re, subprocess, sys, tempfile, time
from pathlib import Path

import numpy as np
from PIL import Image

HARNESS = Path(__file__).resolve().parent
CAL = Path.home() / ".cache" / "harness-tapcv.json"  # px per unit, learned per screen size
TOL = 14       # px (at 1170 wide ≈ 4.5 pt): close enough to click a button
TRIES = 6      # correction rounds before giving up on a tap
STEP = 120     # one `move` report is at most 127 units


def run(cmd: list[str]) -> str:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=180).stdout


def hid(commands: str, stay: bool = True) -> None:
    """Board commands through the app; `stay` keeps the pointer where the moves put it (else the app homes it
    again and tracks it from there)."""
    out = subprocess.run([str(HARNESS / "hid.sh"), commands + ("; stay" if stay else "")], capture_output=True, text=True,
                         timeout=180, env={**os.environ, "NO_LAUNCH": "1"}).stdout
    if "harness hid: done" not in out:
        sys.exit("hid failed: " + out.strip()[-300:])


def shot(path: str | None = None) -> np.ndarray:
    path = path or tempfile.mktemp(suffix=".png")
    subprocess.run([os.environ.get("HARNESS_SHOT", "iphone-dvtshot"), path], capture_output=True, timeout=60)
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.int16)


def moves(dx: float, dy: float, step: int = STEP) -> str:
    """Split a move into reports of at most step units: x first, then y."""
    out = []
    for axis, d in ((0, round(dx)), (1, round(dy))):
        while d:
            s = max(-step, min(step, d))
            out.append(f"move {s} 0" if axis == 0 else f"move 0 {s}")
            d -= s
    return "; ".join(out)


def find_pointer(before: np.ndarray, after: np.ndarray, near: tuple[float, float]) -> tuple[float, float] | None:
    """The pointer in `after`: grey pixels that changed since `before`, nearest blob to `near`."""
    diff = np.abs(after - before).sum(axis=2) > 60
    r, g, b = after[..., 0], after[..., 1], after[..., 2]
    grey = (np.abs(r - g) < 14) & (np.abs(g - b) < 14)
    mask = diff & grey
    mask[: int(after.shape[0] * 0.02)] = False  # the clock
    ys, xs = np.nonzero(mask)
    if len(xs) < 30:
        return None
    # densest spot near the guess: pixels within a pointer-sized window around the nearest changed grey pixel
    d = (xs - near[0]) ** 2 + (ys - near[1]) ** 2
    cx, cy = xs[np.argmin(d)], ys[np.argmin(d)]
    for _ in range(3):  # recentre on the blob
        w = (np.abs(xs - cx) < 45) & (np.abs(ys - cy) < 45)
        cx, cy = xs[w].mean(), ys[w].mean()
    return float(cx), float(cy)


def load_cal(size: tuple[int, int]) -> list[float]:
    try:
        return json.loads(CAL.read_text())[f"{size[0]}x{size[1]}"]
    except Exception:
        return [size[0] / 340, size[1] / 1000]  # a first guess; refined by every landing


def save_cal(size: tuple[int, int], k: list[float]) -> None:
    data = json.loads(CAL.read_text()) if CAL.exists() else {}
    data[f"{size[0]}x{size[1]}"] = k
    CAL.parent.mkdir(parents=True, exist_ok=True)
    CAL.write_text(json.dumps(data))


def point(x: float, y: float, tol: float = TOL) -> np.ndarray:
    """Put the pointer within tol px of (x, y); returns the last screenshot. The app's `point` command gets it close
    (its own calibration, checked on the mirrored picture): long raw moves land far off, as iOS speeds the pointer
    up on big reports (2026-11-26: 290 units right went past the screen edge, 111 down went 440 px). Then small
    corrections, seen on screenshots. A big target (a tab, a row) can take a wider tol."""
    hid("home", stay=False)  # the app's `point` moves from where it tracks the pointer: home it the app's way
    before = shot()
    h, w = before.shape[0], before.shape[1]
    hid(f"point {x / w * 1000:.0f} {y / h * 1000:.0f}")
    k0 = load_cal((w, h))
    k = list(k0)
    at, last, sent = (x, y), None, None
    for i in range(TRIES):
        after = shot()
        p = find_pointer(before, after, at)
        if p is None:
            sys.exit("pointer not found on the screenshot")
        ex, ey = x - p[0], y - p[1]
        print(f"pointer at {p[0]:.0f},{p[1]:.0f}, off by {ex:.0f},{ey:.0f} px")
        if abs(ex) <= tol and abs(ey) <= tol:
            return after
        # px per unit as the last correction moved it: iOS speeds up even 20-unit reports, so the stored scale
        # overshot 3-4x and the pointer swung past the target every round (2026-11-26: off -42 px, then +129)
        if last and sent:
            for a in (0, 1):
                if abs(sent[a]) >= 3:
                    # within 0.5-4x of the stored scale: a mis-found pointer (an animating Control Center) must not set it
                    k[a] = min(max(abs(p[a] - last[a]) / abs(sent[a]), k0[a] / 2), k0[a] * 4)
        before, at, last = after, (x, y), p
        sent = (round(ex / k[0]), round(ey / k[1]))
        hid(moves(*sent, step=20))
    sys.exit(f"could not land within {tol:.0f} px of {x:.0f},{y:.0f}")


def ocr(img: np.ndarray) -> list[dict]:
    cmd = os.environ.get("HARNESS_OCR")
    if not cmd:
        sys.exit("text needs HARNESS_OCR (an OCR command for an image path)")
    path = tempfile.mktemp(suffix=".png")
    Image.fromarray(img.astype(np.uint8)).save(path)
    return json.loads(run([cmd, path]) or "[]")


def find_text(img: np.ndarray, text: str) -> tuple[float, float] | None:
    hits = [b for b in ocr(img) if text.lower() in b["text"].lower()]
    if not hits:
        return None
    b = min(hits, key=lambda b: len(b["text"]))  # the tightest match
    return b["x"] + b["w"] / 2, b["y"] + b["h"] / 2


def tap(x: float, y: float, expect: str | None = None, wait: float = 1.5, tol: float = TOL) -> bool:
    before = point(x, y, tol)
    # the pointer hides after a few idle seconds (the correction screenshots), and then a click only shows it again:
    # a one-unit wiggle first, in the same batch (2026-11-26: back arrows "did nothing" until clicked twice)
    hid("move 1 0; move -1 0; click")
    time.sleep(wait)
    after = shot()
    changed = float((np.abs(after - before).sum(axis=2) > 60).mean())
    ok = changed > 0.01 and (expect is None or find_text(after, expect) is not None)
    print(f"tap {x:.0f},{y:.0f}: screen changed {changed:.1%}" + (f", '{expect}' {'seen' if ok else 'not seen'}" if expect else ""))
    return ok


def open_control_center() -> np.ndarray:
    """Press in the top-right corner and drag down, like a finger (a click there does nothing)."""
    hid("home; " + moves(600, 0) + "; move 0 -80; press; " + "; ".join(["move 0 40"] * 6) + "; release")
    time.sleep(1)
    return shot()


def mirroring_menu(board: str) -> np.ndarray:
    """Control Center, then the Screen Mirroring tile (no text on it): the guess whose tap shows the board's name."""
    img = open_control_center()
    if find_text(img, board) is None:
        for p in mirroring_button_guesses(img):
            if tap(*p, tol=40) and listed(board):  # a tile 150 px across
                break
        else:
            sys.exit("Screen Mirroring menu not found")
    return shot()


def listed(board: str, seconds: float = 6) -> bool:
    """The Screen Mirroring menu lists its devices a few seconds after it opens (2026-11-26: the board's name was
    not there 1.5 s after the tap, so the menu was taken for the wrong tile and a run waited 5 min for a picture)."""
    end = time.time() + seconds
    while True:
        if find_text(shot(), board) is not None:
            return True
        if time.time() > end:
            return False
        time.sleep(1)


def mirror(board: str, restart: bool = False) -> bool:
    """Mirror to BOARD; --restart stops the session first (a new app process needs the keyframe a start sends)."""
    img = mirroring_menu(board)
    if restart and (stop := find_text(img, "Stop Mirroring")):
        tap(*stop)
        time.sleep(2)
        img = mirroring_menu(board)
    # The list fills in for a few seconds and rows move: wait until the board's row stays put, then check it is
    # still under the pointer before the click (2026-11-26: the row moved down while the pointer was on its way,
    # and the click went into the Mac mini above it, mirroring the phone there)
    spot, prev = None, None
    for _ in range(8):
        spot = find_text(shot(), board)
        if spot and prev and abs(spot[1] - prev[1]) < 10:
            break
        prev = spot
        time.sleep(1)
    if spot is None:
        sys.exit(f"{board} not in the Screen Mirroring list")
    for _ in range(3):
        landed = point(*spot, tol=20)
        now_at = find_text(landed, board)
        if now_at and abs(now_at[1] - spot[1]) < 25:
            break
        spot = now_at or spot  # it moved: point again at where it is now
    else:
        sys.exit(f"{board}'s row kept moving; not clicking")
    hid("move 1 0; move -1 0; click")
    time.sleep(1.5)
    ok = False
    for _ in range(20):  # connected: the menu now offers Stop Mirroring
        time.sleep(1.5)
        if find_text(shot(), "Stop Mirroring"):
            ok = True
            break
    close_control_center()
    # "Stop Mirroring" shows while it still connects: a picture reaching the app is the proof (2026-11-26: "✓",
    # then no frame and a run waited 5 minutes)
    ok = ok and pictured()
    print("mirroring to " + board + (" ✓" if ok else ": not confirmed"))
    return ok


def pictured(seconds: float = 12) -> bool:
    """A picture arrives now (the app's `video`: board streaming, nothing frozen, a recent frame). The app's last
    frame alone is no proof (2026-11-26: after the board restarted, `hid.sh shot` saved the one from before it and
    mirroring was taken for on); nor `snap`, which sends the board's whole GOP and timed out at 15 s once it was MBs."""
    end = time.time() + seconds
    while True:
        out = subprocess.run([str(HARNESS / "hid.sh"), "video"], capture_output=True, text=True, timeout=180,
                             env={**os.environ, "NO_LAUNCH": "1"}).stdout
        if "video → live" in out:
            return True
        if time.time() > end:
            return False
        time.sleep(2)


def close_control_center() -> None:
    """Empty space under its tiles, until the status bar's clock is back (Control Center hides it): from the Screen
    Mirroring menu the first tap only goes back to Control Center (2026-11-26: a run then started under it)."""
    for i in range(3):
        if i:
            time.sleep(1)  # the closing slide: read before it ends, the clock was missed and a third tap went into the app
        img = shot()
        if any(re.fullmatch(r"\d{1,2}:\d{2}", b["text"]) and b["y"] < img.shape[0] * 0.04 for b in ocr(img)):
            return
        tap(img.shape[1] * 0.5, img.shape[0] * 0.86, tol=80)


def mirroring_button_guesses(img: np.ndarray) -> list[tuple[float, float]]:
    """Where the Screen Mirroring tile sits in the default Control Center: left column, the row under the
    connectivity block (its width share is the same on every iPhone; height share as measured on iOS 27)."""
    h, w = img.shape[0], img.shape[1]
    return [(w * 0.395, h * 0.414), (w * 0.395, h * 0.447)]


if __name__ == "__main__":
    a = sys.argv[1:]
    expect = a[a.index("--expect") + 1] if "--expect" in a else None
    if not a:
        sys.exit(__doc__)
    if a[0] == "shot":
        out = a[1] if len(a) > 1 else "/tmp/tapcv.png"
        Image.fromarray(shot().astype(np.uint8)).save(out); print(out)
    elif a[0] == "tap":
        tol = float(a[a.index("--tol") + 1]) if "--tol" in a else TOL
        sys.exit(0 if tap(float(a[1]), float(a[2]), expect, tol=tol) else 1)
    elif a[0] == "tap-text":
        p = find_text(shot(), a[1])
        if p is None:
            sys.exit(f"'{a[1]}' not on screen")
        sys.exit(0 if tap(*p, expect) else 1)
    elif a[0] == "mirror":
        sys.exit(0 if mirror(a[1], restart="--restart" in a) else 1)
    else:
        sys.exit(__doc__)
