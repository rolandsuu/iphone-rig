"""Command line for testing the rig by hand.

  uv run rig status             feed, board, pairing, calibration
  uv run rig autostart on|off   start the hidden capture helper at login (and keep it running)
  uv run rig start              start the hidden capture helper now
  uv run rig stop               stop the capture helper (until `start` or the next login)
  uv run rig window             debug: the standalone viewer window instead of the hidden helper
  uv run rig snap out.jpg       save a screenshot (400 px wide, the same image Claude sees)
  uv run rig calibrate          measure pointer movement (do this once after pairing)
  uv run rig tap X Y            tap in screenshot pixels
  uv run rig swipe X1 Y1 X2 Y2
  uv run rig type "hello"
  uv run rig key cmd+space
  uv run rig home
  uv run rig raw "MOVE 100 0"   send a raw firmware command
Add --dry-run to print board commands instead of sending them.
"""

from __future__ import annotations

import argparse
import sys

from . import RigError
from .control import Rig


def main() -> None:
    p = argparse.ArgumentParser(prog="rig", description="iPhone rig tester")
    p.add_argument("--dry-run", action="store_true", help="print board commands instead of sending them")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    au = sub.add_parser("autostart"); au.add_argument("state", choices=["on", "off"])
    sub.add_parser("start")
    sub.add_parser("stop")
    sub.add_parser("window")
    s = sub.add_parser("snap"); s.add_argument("out")
    c = sub.add_parser("calibrate"); c.add_argument("--counts", type=int, default=150)
    t = sub.add_parser("tap"); t.add_argument("x", type=float); t.add_argument("y", type=float)
    sw = sub.add_parser("swipe")
    for n in ("x1", "y1", "x2", "y2"):
        sw.add_argument(n, type=float)
    ty = sub.add_parser("type"); ty.add_argument("text")
    k = sub.add_parser("key"); k.add_argument("combo")
    sub.add_parser("home")
    r = sub.add_parser("raw"); r.add_argument("line")
    a = p.parse_args()

    rig = Rig(dry_run=True if a.dry_run else None)
    try:
        if a.cmd == "status":
            from . import server as srv
            srv._rig = rig
            print(srv.rig_status())
        elif a.cmd == "autostart":
            rig.eyes.autostart(a.state == "on")
            if a.state == "on":
                rig.eyes.ensure_running()
                print("autostart on: the hidden helper runs now and starts at every login")
            else:
                print("autostart off: helper stopped and removed from login")
        elif a.cmd == "start":
            rig.eyes.launch()
            rig.eyes.ensure_running()
            print("capture helper running (hidden)")
        elif a.cmd == "stop":
            rig.eyes.stop()
            print("capture helper stopped")
        elif a.cmd == "window":
            rig.eyes.stop()
            rig.eyes.launch(window=True)
            print("opened the iPhone Rig window")
        elif a.cmd == "snap":
            data, w, h = rig.screenshot()
            open(a.out, "wb").write(data)
            print(f"{a.out} {w}x{h}")
        elif a.cmd == "calibrate":
            rig.calibrate(n=a.counts)
        elif a.cmd == "tap":
            rig.tap(a.x, a.y)
        elif a.cmd == "swipe":
            rig.swipe(a.x1, a.y1, a.x2, a.y2)
        elif a.cmd == "type":
            rig.type_text(a.text)
        elif a.cmd == "key":
            rig.key(a.combo)
        elif a.cmd == "home":
            rig.home()
        elif a.cmd == "raw":
            print(rig.hands.cmd(a.line))
    except RigError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
