"""Rig: screenshots in, taps out. Shared by the MCP server and the CLI.

Coordinates given to the public methods are pixels in the screenshot image
that Claude sees (VIEW_WIDTH px wide). They are converted to full-resolution
frame pixels, then to mouse counts using calibration.json.
"""

from __future__ import annotations

import json
import os
import time
from io import BytesIO

from PIL import Image

from . import CALIBRATION, RigError
from .eyes import Eyes, find_pointer, locate_pointer
from .hands import Hands

VIEW_WIDTH = int(os.environ.get("RIG_VIEW_WIDTH", "400"))

DEFAULT_CAL = {
    "kx": 0.35, "ky": 0.35,      # mouse counts per frame pixel (rough guess until calibrated)
    "ox": 0.0, "oy": 0.0,        # frame pixel the pointer sits at after CORNER
    "step": 8, "delay": 6,       # firmware pointer step size and pause; keep fixed after calibrating
    "recorner_every": 4,         # re-anchor in the corner every N actions to cancel drift
    "calibrated": False,
}


def load_cal() -> dict:
    cal = dict(DEFAULT_CAL)
    if CALIBRATION.exists():
        cal.update(json.loads(CALIBRATION.read_text()))
    return cal


def save_cal(cal: dict) -> None:
    CALIBRATION.write_text(json.dumps(cal, indent=2) + "\n")


class Rig:
    def __init__(self, dry_run: bool | None = None):
        self.eyes = Eyes()
        self.hands = Hands(dry_run=dry_run)
        self.cal = load_cal()
        self.actions_since_corner = 10**6
        self.configured = False

    # ---- geometry ----

    def frame_size(self) -> tuple[int, int]:
        meta = self.eyes.ensure_running()
        return int(meta["width"]), int(meta["height"])

    def view_size(self) -> tuple[int, int]:
        w, h = self.frame_size()
        return VIEW_WIDTH, round(h * VIEW_WIDTH / w)

    def to_frame(self, x: float, y: float) -> tuple[float, float]:
        w, h = self.frame_size()
        vw, vh = self.view_size()
        if not (0 <= x <= vw and 0 <= y <= vh):
            raise RigError(f"({x}, {y}) is outside the screenshot ({vw}x{vh}).")
        s = w / VIEW_WIDTH
        return x * s, y * s

    def to_counts(self, fx: float, fy: float) -> tuple[int, int]:
        c = self.cal
        return round((fx - c["ox"]) * c["kx"]), round((fy - c["oy"]) * c["ky"])

    # ---- screenshots ----

    def screenshot(self, settle: bool = False) -> tuple[bytes, int, int]:
        img = self.eyes.wait_still() if settle else self.eyes.frame()[0]
        vw = VIEW_WIDTH
        vh = round(img.height * vw / img.width)
        small = img.convert("RGB").resize((vw, vh), Image.LANCZOS)
        buf = BytesIO()
        small.save(buf, "JPEG", quality=80)
        return buf.getvalue(), vw, vh

    # ---- pointer ----

    def _prepare(self) -> None:
        if not self.configured:
            self.hands.configure(self.cal["step"], self.cal["delay"])
            self.configured = True
        if self.actions_since_corner >= self.cal["recorner_every"]:
            self.hands.corner()
            self.actions_since_corner = 0
            self.pointer = None          # somewhere in the top-left corner
        self.actions_since_corner += 1

    pointer: tuple[float, float] | None = None   # last seen pointer position, frame pixels

    def _aim(self, fx: float, fy: float, tries: int = 2, tol: float = 14.0) -> None:
        """Move the pointer onto frame pixel (fx, fy), checking where it really landed.

        iOS pointer acceleration makes counts-to-pixels only roughly linear, so after the
        first move the pointer is found in the screen feed and the remaining error is
        corrected (up to `tries` times). Falls back to the open-loop move if the pointer
        can't be seen (e.g. the screen is animating).
        """
        self._prepare()
        before = self.eyes.frame()[0]
        if self.pointer is None:
            self.hands.move_to(*self.to_counts(fx, fy))
        else:
            px, py = self.pointer
            self.hands.move(round((fx - px) * self.cal["kx"]), round((fy - py) * self.cal["ky"]))
        expect = (fx, fy)
        for _ in range(tries + 1):
            after = self.eyes.wait_still(timeout=1.5, settle=0.25)
            p = locate_pointer(before, after, expect)
            if p is None:
                self.pointer = None
                return
            self.pointer = p
            ex, ey = fx - p[0], fy - p[1]
            if abs(ex) <= tol and abs(ey) <= tol:
                return
            mx, my = round(ex * self.cal["kx"]), round(ey * self.cal["ky"])
            if mx == 0 and my == 0:
                return
            before = after
            self.hands.move(mx, my)
            expect = (fx, fy)

    def tap(self, x: float, y: float, hold_ms: int = 50) -> None:
        fx, fy = self.to_frame(x, y)
        self.eyes.mark(fx, fy, f"tap {round(x)},{round(y)}" if hold_ms < 300 else f"press {round(x)},{round(y)}")
        self._aim(fx, fy)
        self.hands.click(hold_ms)
        self.pointer = None if hold_ms >= 300 else self.pointer

    def swipe(self, x1: float, y1: float, x2: float, y2: float) -> None:
        f1, f2 = self.to_frame(x1, y1), self.to_frame(x2, y2)
        self.eyes.mark(*f1, f"swipe to {round(x2)},{round(y2)}")
        self._prepare()
        c1, c2 = self.to_counts(*f1), self.to_counts(*f2)
        self.hands.move_to(*c1)
        self.hands.down()
        try:
            self.hands.move(c2[0] - c1[0], c2[1] - c1[1])
        finally:
            self.hands.up()
        self.eyes.mark(*f2, "")

    def scroll(self, x: float, y: float, amount: int) -> None:
        fx, fy = self.to_frame(x, y)
        self.eyes.mark(fx, fy, f"scroll {amount:+d}")
        self._prepare()
        self.hands.move_to(*self.to_counts(fx, fy))
        self.hands.scroll(amount)

    def type_text(self, text: str) -> None:
        self.eyes.mark(None, None, "type: " + (text if len(text) <= 28 else text[:25] + "..."))
        self.hands.type(text)

    def key(self, combo: str) -> None:
        self.eyes.mark(None, None, "key: " + combo)
        self.hands.key(combo)

    def home(self) -> None:
        """Press Home: the HID consumer key "AC Home" (0x223) from the Bluetooth keyboard.

        A pointer swipe up from the bottom edge opens the App Switcher instead (iOS reads
        it as swipe-and-hold), so the key is used. From an app or the App Switcher one press
        may land on an overlay (e.g. Search); press again to reach the home screen.
        """
        self.eyes.mark(None, None, "home")
        self.hands.consumer(0x223)

    # ---- calibration ----

    def calibrate(self, n: int = 150, log=print) -> dict:
        """Measure how far the pointer moves on screen per mouse count."""
        h, e = self.hands, self.eyes
        h.configure(self.cal["step"], self.cal["delay"])
        self.configured = True
        h.corner()
        f0 = e.wait_still(timeout=2.5, settle=0.3)
        h.move(n, n)
        f1 = e.wait_still(timeout=2.5, settle=0.3)
        pa = find_pointer(f0, f1, avoid=(0, 0))
        h.move(n, 0)
        f2 = e.wait_still(timeout=2.5, settle=0.3)
        pb = find_pointer(f1, f2, avoid=pa)
        h.move(0, n)
        f3 = e.wait_still(timeout=2.5, settle=0.3)
        pc = find_pointer(f2, f3, avoid=pb)
        log(f"pointer positions: A={pa} B={pb} C={pc}")
        if not (pa and pb and pc) or abs(pb[0] - pa[0]) < 5 or abs(pc[1] - pb[1]) < 5:
            raise RigError("Could not see the pointer move. Turn on AssistiveTouch, set Pointer "
                           "Auto-Hide off, keep the iPhone on a plain screen (home screen), and retry.")
        kx = n / (pb[0] - pa[0])
        ky = n / (pc[1] - pb[1])
        cal = dict(self.cal, kx=round(kx, 5), ky=round(ky, 5),
                   ox=round(pa[0] - n / kx, 1), oy=round(pa[1] - n / ky, 1),
                   calibrated=True, calibrated_at=time.strftime("%Y-%m-%d %H:%M"))
        save_cal(cal)
        self.cal = cal
        self.actions_since_corner = 10**6
        log(f"saved {CALIBRATION.name}: kx={cal['kx']} ky={cal['ky']} origin=({cal['ox']}, {cal['oy']})")
        return cal
