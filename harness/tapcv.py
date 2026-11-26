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
import json, os, subprocess, sys, tempfile, time
from pathlib import Path

import numpy as np
from PIL import Image

HARNESS = Path(__file__).resolve().parent
CAL = Path.home() / ".cache" / "harness-tapcv.json"  # px per unit, learned per screen size
TOL = 14       # px (at 1170 wide ≈ 4.5 pt): close enough to click a button
TRIES = 4      # correction rounds before giving up on a tap
STEP = 120     # one `move` report is at most 127 units


def run(cmd: list[str]) -> str:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=180).stdout


def hid(commands: str) -> None:
    """Board commands through the app; `stay` keeps the pointer where the moves put it."""
    out = subprocess.run([str(HARNESS / "hid.sh"), commands + "; stay"], capture_output=True, text=True,
                         timeout=180, env={**os.environ, "NO_LAUNCH": "1"}).stdout
    if "harness hid: done" not in out:
        sys.exit("hid failed: " + out.strip()[-300:])


def shot(path: str | None = None) -> np.ndarray:
    path = path or tempfile.mktemp(suffix=".png")
    subprocess.run([os.environ.get("HARNESS_SHOT", "iphone-dvtshot"), path], capture_output=True, timeout=60)
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.int16)


def moves(dx: float, dy: float) -> str:
    """Split a move into reports of at most STEP units: x first, then y."""
    out = []
    for axis, d in ((0, round(dx)), (1, round(dy))):
        while d:
            s = max(-STEP, min(STEP, d))
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


def point(x: float, y: float) -> np.ndarray:
    """Put the pointer on (x, y) px; returns the last screenshot."""
    hid("home")
    before = shot()
    size = (before.shape[1], before.shape[0])
    k = load_cal(size)
    hid("home; " + moves(x / k[0], y / k[1]))
    at, sent = (0.0, 0.0), (x / k[0], y / k[1])
    for i in range(TRIES):
        after = shot()
        p = find_pointer(before, after, (at[0] + sent[0] * k[0], at[1] + sent[1] * k[1]))
        if p is None:
            sys.exit("pointer not found on the screenshot")
        # learn the scale from this move (only from long moves: short ones are mostly rounding)
        for a in (0, 1):
            if abs(sent[a]) > 40:
                k[a] = 0.7 * k[a] + 0.3 * abs((p[a] - at[a]) / sent[a])
        save_cal(size, k)
        ex, ey = x - p[0], y - p[1]
        print(f"pointer at {p[0]:.0f},{p[1]:.0f}, off by {ex:.0f},{ey:.0f} px")
        if abs(ex) <= TOL and abs(ey) <= TOL:
            return after
        before, at, sent = after, p, (ex / k[0], ey / k[1])
        hid(moves(*sent))
    sys.exit(f"could not land within {TOL} px of {x:.0f},{y:.0f}")


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


def tap(x: float, y: float, expect: str | None = None, wait: float = 1.5) -> bool:
    before = point(x, y)
    hid("click")
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
            if tap(*p, expect=board):
                break
        else:
            sys.exit("Screen Mirroring menu not found")
    return shot()


def mirror(board: str, restart: bool = False) -> bool:
    """Mirror to BOARD; --restart stops the session first (a new app process needs the keyframe a start sends)."""
    img = mirroring_menu(board)
    if restart and (stop := find_text(img, "Stop Mirroring")):
        tap(*stop)
        time.sleep(2)
        img = mirroring_menu(board)
    spot = find_text(img, board)
    tap(*spot, expect="Connecting")
    ok = False
    for _ in range(20):  # connected: the menu now offers Stop Mirroring
        time.sleep(1.5)
        if find_text(shot(), "Stop Mirroring"):
            ok = True
            break
    img = shot()
    tap(img.shape[1] * 0.5, img.shape[0] * 0.86)  # close Control Center: empty space under its tiles
    print("mirroring to " + board + (" ✓" if ok else ": not confirmed"))
    return ok


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
        sys.exit(0 if tap(float(a[1]), float(a[2]), expect) else 1)
    elif a[0] == "tap-text":
        p = find_text(shot(), a[1])
        if p is None:
            sys.exit(f"'{a[1]}' not on screen")
        sys.exit(0 if tap(*p, expect) else 1)
    elif a[0] == "mirror":
        sys.exit(0 if mirror(a[1], restart="--restart" in a) else 1)
    else:
        sys.exit(__doc__)
