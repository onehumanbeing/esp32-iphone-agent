"""Where a run's time went, from the app's debug.log: per step and in total, frame (waiting for the screen to settle),
verdict (checking the last action landed), LLM (the model's answer), HID (the board doing it) and other.
Usage: python3 harness/timing.py <debug.log> [run start time, e.g. 2026-11-26T04:09]   (default: the last run)
"""
import re, sys

lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
starts = [i for i, l in enumerate(lines) if " started: " in l and (len(sys.argv) < 3 or l.startswith(sys.argv[2]))]
if not starts:
    sys.exit("no run start found")
first = starts[0] if len(sys.argv) > 2 else starts[-1]
end = next((i for i in range(first, len(lines)) if " finished: " in lines[i]), len(lines) - 1)
run = lines[first:end + 1]

PARTS = ("frame", "verdict", "LLM", "HID", "other")
total = dict.fromkeys(PARTS, 0)
rows = []
for l in run:
    m = re.search(r"step (\d+) timing: (.*)", l)
    if not m:
        continue
    ms = {p: int(v) for p, v in re.findall(r"\b(frame|verdict|LLM|HID|other) (\d+) ms", m.group(2))}
    rows.append((int(m.group(1)), ms))
    for p in PARTS:
        total[p] += ms.get(p, 0)

acts = {}
for l in run:
    m = re.search(r"step (\d+): (\w+)", l)
    if m and "timing" not in l:
        acts.setdefault(int(m.group(1)), m.group(2))

t0, t1 = run[0][:23], run[-1][:23]
print(f"run {t0} → {t1}, {len(rows)} model steps")
print(f"{'step':>4}  " + "  ".join(f"{p:>7}" for p in PARTS) + "   sum")
for n, ms in rows:
    print(f"{n:>4}  " + "  ".join(f"{ms.get(p, 0) / 1000:7.1f}" for p in PARTS) + f"  {sum(ms.values()) / 1000:5.1f}")
s = sum(total.values()) or 1
print("total " + "  ".join(f"{p} {total[p] / 1000:.0f}s ({total[p] / s:.0%})" for p in PARTS))
print("final: " + run[-1][25:200])
