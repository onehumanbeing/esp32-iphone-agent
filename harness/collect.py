# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow"]
# ///
"""Walk an app's screens with the board and record each one: the screenshot, the text on it (OCR boxes) and the
step that led there (the screen before, the action, where it went). Screen -> action -> next screen, for training
and for the app guides. Taps are tapcv's closed loop (find the pointer, correct, click, check).

  uv run harness/collect.py PLAN.json OUT_DIR

PLAN is a JSON list of steps, each with a "name" for the screen it leads to:
  {"name": "contacts", "tap": [437, 2394]}     tap at x y (screenshot pixels)
  {"name": "new_friends", "tap": "新的朋友"}    tap the words, found by OCR
  {"name": "menu", "hold": [600, 1500]}         long press
  {"name": "moments", "back": true}             the back arrow at the top left
  {"name": "moments_loaded", "wait": 3}         wait, then record the screen again
Words in NEVER are never tapped, whatever the plan says: collecting only looks.
Writes OUT_DIR/NNN-name.png, OUT_DIR/NNN-name.json (OCR) and OUT_DIR/steps.jsonl.
"""
import json, sys, time
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tapcv  # noqa: E402

NEVER = ("发送", "添加到通讯录", "发表", "转账", "红包", "删除", "视频通话", "语音通话", "支付", "付款", "确定",
         "Send", "Delete", "Post", "Pay", "Add to Contacts")
BACK = (0.056, 0.081)  # the back arrow, as shares of the screen
TOL = 40  # px: UI targets here are 120 px or more at 1170 wide


def blocked(text: str) -> bool:
    return any(w in text for w in NEVER)


def main(plan_path: str, out: str) -> None:
    plan = json.loads(Path(plan_path).read_text())
    out_dir = Path(out)
    out_dir.mkdir(parents=True, exist_ok=True)
    log = (out_dir / "steps.jsonl").open("a")
    img = tapcv.shot()
    prev = "start"
    for i, step in enumerate(plan, 1):
        name, h, w = step["name"], img.shape[0], img.shape[1]
        action: dict = {}
        try:
            if isinstance(step.get("tap"), str):
                words = step["tap"]
                hits = [b for b in tapcv.ocr(img) if words in b["text"]]
                hit = min(hits, key=lambda b: len(b["text"])) if hits else None
                if hit is None or blocked(hit["text"]):  # the next steps assume this screen: stop
                    print(f"{i} {name}: '{words}' {'blocked' if hit else 'not on screen'}; stopped", flush=True)
                    log.write(json.dumps({"n": i, "to": name, "failed": f"'{words}' not tapped"}, ensure_ascii=False) + "\n")
                    return
                x, y = hit["x"] + hit["w"] / 2, hit["y"] + hit["h"] / 2
                action = {"action": "tap", "text": hit["text"], "box": [hit["x"], hit["y"], hit["w"], hit["h"]]}
                tapcv.tap(x, y, tol=step.get("tol", TOL))
            elif "tap" in step:
                x, y = step["tap"]
                action = {"action": "tap"}
                tapcv.tap(x, y, tol=step.get("tol", TOL))
            elif "hold" in step:
                x, y = step["hold"]
                action = {"action": "hold"}
                tapcv.point(x, y, step.get("tol", TOL))
                tapcv.hid("press")
                time.sleep(1.0)
                tapcv.hid("release")
            elif step.get("back"):  # a small arrow near the edge: a tight landing, and the screen must change
                x, y = w * BACK[0], h * BACK[1]
                action = {"action": "back"}
                if not tapcv.tap(x, y, tol=step.get("tol", 18)):
                    raise SystemExit("back left the screen as it was")
            elif "wait" in step:
                x = y = None
                action = {"action": "wait", "seconds": step["wait"]}
                time.sleep(step["wait"])
        except SystemExit as e:  # tapcv gave up: later steps assume this screen, so stop here
            print(f"{i} {name}: {e}; stopped (the next steps start from this screen)", flush=True)
            log.write(json.dumps({"n": i, "to": name, "failed": str(e)}, ensure_ascii=False) + "\n")
            return
        if x is not None:
            action["at"] = [round(x), round(y)]
            action["at_1000"] = [round(x / w * 1000), round(y / h * 1000)]
        time.sleep(step.get("settle", 1.2))
        png = out_dir / f"{i:03d}-{name}.png"
        img = tapcv.shot(str(png))
        boxes = tapcv.ocr(img)
        (out_dir / f"{i:03d}-{name}.json").write_text(json.dumps(boxes, ensure_ascii=False))
        log.write(json.dumps({"n": i, "from": prev, "to": name, **action, "screen": png.name,
                              "size": [w, h], "t": time.time()}, ensure_ascii=False) + "\n")
        log.flush()
        print(f"{i} {prev} -> {name}: {action.get('action')} {action.get('text', '')} ({len(boxes)} text boxes)", flush=True)
        prev = name


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
