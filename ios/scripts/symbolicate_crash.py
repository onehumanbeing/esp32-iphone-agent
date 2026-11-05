#!/usr/bin/env python3
"""Turn a crash from the field into function names, with the build's dSYM.

    ios/scripts/symbolicate_crash.py crash.json
    ios/scripts/symbolicate_crash.py crash.json --dsym path/to/IPhoneAgent.app.dSYM

crash.json is any of: a MetricKit report from the app (Documents/diagnostics, or Logs > Export all logs), or the
`call_stack` property of a PostHog crash_report event pasted into a file. The crashed thread is printed innermost
first; frames in the app get function and line from the dSYM, found by UUID with Spotlight (Xcode keeps one per
archive in ~/Library/Developer/Xcode/Archives) unless --dsym is given.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

LOAD = 0x100000000  # any load address works: offsets are from the start of __TEXT


def find_stacks(node):
    if isinstance(node, dict):
        if "callStacks" in node:
            return node["callStacks"]
        node = list(node.values())
    if isinstance(node, list):
        for v in node:
            found = find_stacks(v)
            if found:
                return found
    if isinstance(node, str) and "callStacks" in node:
        return find_stacks(json.loads(node))
    return None


def crashed_frames(stacks):
    stack = next((s for s in stacks if s.get("threadAttributed")), stacks[0])
    frames, level = [], stack.get("callStackRootFrames")
    while level:
        f = level[0]
        frames.append(f)
        level = f.get("subFrames")
    return frames


def dsym_for(uuid, given):
    if given:
        return given
    out = subprocess.run(["mdfind", f"com_apple_xcode_dsym_uuids == {uuid}"], capture_output=True, text=True).stdout
    return Path(out.splitlines()[0]) if out.strip() else None


def dwarf(dsym: Path, binary: str) -> Path:
    if dsym.suffix != ".dSYM":
        found = next(dsym.rglob(f"{binary}.app.dSYM"), None)  # an .xcarchive folder
        dsym = found or dsym
    return dsym / "Contents/Resources/DWARF" / binary


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("crash", type=Path)
    ap.add_argument("--dsym", type=Path)
    a = ap.parse_args()
    stacks = find_stacks(json.loads(a.crash.read_text()))
    if not stacks:
        sys.exit("no MetricKit call stack in this file")
    frames = crashed_frames(stacks)
    names = {}
    for uuid in {f["binaryUUID"] for f in frames if f.get("binaryName") == "IPhoneAgent"}:
        dsym = dsym_for(uuid, a.dsym)
        if not dsym:
            print(f"no dSYM for IPhoneAgent {uuid}: pass --dsym (Xcode Organizer > Archives > Show in Finder)", file=sys.stderr)
            continue
        app = [f for f in frames if f.get("binaryUUID") == uuid]
        addrs = [hex(LOAD + f["offsetIntoBinaryTextSegment"]) for f in app]
        out = subprocess.run(["atos", "-arch", "arm64", "-o", str(dwarf(dsym, "IPhoneAgent")), "-l", hex(LOAD), *addrs],
                             capture_output=True, text=True).stdout.splitlines()
        for f, line in zip(app, out):
            names[id(f)] = line
    for i, f in enumerate(frames):
        where = names.get(id(f), f"+ 0x{f['offsetIntoBinaryTextSegment']:x}")
        print(f"{i:3}  {f.get('binaryName', '?'):<28} {where}")


if __name__ == "__main__":
    main()
