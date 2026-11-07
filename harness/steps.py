"""Print a run's steps from row N on, one line each, for harness/watch.sh. The last line is the row count."""
import json, sys

lines = open(sys.argv[1]).read().splitlines()
for line in lines[int(sys.argv[2]):]:
    try:
        r = json.loads(line)
    except ValueError:
        continue
    kind, act = r.get("kind"), r.get("action", "")
    if kind == "verdict":
        print(f"     -> {'changed' if r.get('changed') else 'NO CHANGE'}, pointer at {r.get('pointer', '?')}")
    elif kind == "step" and act != "plan":
        args = " ".join(str(r[k]) for k in ("x", "y", "text", "combo", "app") if k in r)
        why = (r.get("thought") or "").replace("\n", " ")[:120]
        print(f"#{r['n']} {act} {args}  | {why}".rstrip(" |"))
    elif kind == "step":
        print(f"#{r['n']} plan: " + r.get("plan", "").replace("\n", " / ")[:160])
print(len(lines))
