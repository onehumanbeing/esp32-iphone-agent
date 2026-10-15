"""Remote controls for the legacy iPhone server. Run `iphone-agent --help`."""

import argparse
import json
import sys
from pathlib import Path

import httpx

from .client import IPhoneClient


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    root.add_argument("--url", help="server URL; defaults to IPHONE_AGENT_URL or http://127.0.0.1:8890")
    sub = root.add_subparsers(dest="command", required=True)
    for name in ("status", "home", "back", "task-status", "stop", "mcp"):
        sub.add_parser(name)
    shot = sub.add_parser("screenshot")
    shot.add_argument("output", type=Path)
    for name, keys in {"tap": ("x", "y"), "swipe": ("x1", "y1", "x2", "y2"),
                       "scroll": ("x", "y", "lines")}.items():
        action = sub.add_parser(name, help="coordinates are screen fractions from 0 to 1")
        for key in keys:
            action.add_argument(key, type=int if key == "lines" else float)
    for name in ("type", "key"):
        sub.add_parser(name).add_argument("text")
    calibration = sub.add_parser("calibrate")
    calibration.add_argument("--pointer", nargs=2, type=float, metavar=("X", "Y"))
    sub.add_parser("task").add_argument("goal")
    edit = sub.add_parser("edit", help="edit a visibly focused field without an intermediate observation")
    edit.add_argument("text")
    edit.add_argument("--replace", action="store_true")
    edit.add_argument("--submit", action="store_true")
    return root


def main(argv=None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "mcp":
            from .mcp import serve
            serve(args.url)
            return 0
        with IPhoneClient(args.url) as client:
            match args.command:
                case "status": result = client.status()
                case "screenshot":
                    args.output.write_bytes(client.screenshot())
                    result = {"path": str(args.output.resolve())}
                case "tap": result = client.action("tap", x=args.x, y=args.y)
                case "swipe": result = client.action("swipe", x1=args.x1, y1=args.y1, x2=args.x2, y2=args.y2)
                case "scroll": result = client.action("scroll", x=args.x, y=args.y, lines=args.lines)
                case "type" | "key": result = client.action(args.command, text=args.text)
                case "edit": result = client.edit_text(args.text, replace=args.replace, submit=args.submit)
                case "home" | "back": result = client.action(args.command)
                case "calibrate": result = client.calibrate(*(args.pointer or []))
                case "task": result = client.delegate(args.goal)
                case "task-status": result = client.task_status()
                case "stop": result = client.stop()
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (httpx.HTTPError, RuntimeError, ValueError, OSError) as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
