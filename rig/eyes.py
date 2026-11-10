"""Eyes: frames of the iPhone screen, written by iPhone Rig.app."""

from __future__ import annotations

import json
import os
import plistlib
import subprocess
import time
from io import BytesIO
from pathlib import Path

import numpy as np
from PIL import Image

from . import APP, RIG_DIR, RigError

AGENT_LABEL = "local.iphone-rig.capture"
AGENT_PLIST = Path.home() / "Library" / "LaunchAgents" / f"{AGENT_LABEL}.plist"


def _domain() -> str:
    return f"gui/{os.getuid()}"


def _agent_loaded() -> bool:
    return subprocess.run(["launchctl", "print", f"{_domain()}/{AGENT_LABEL}"],
                          capture_output=True).returncode == 0


class Eyes:
    def __init__(self, rig_dir=RIG_DIR, fps: int = 12):
        self.dir = rig_dir
        self.fps = fps
        self.dir.mkdir(parents=True, exist_ok=True)

    # ---- the viewer app ----

    def _meta(self) -> dict | None:
        try:
            return json.loads((self.dir / "latest.json").read_text())
        except (OSError, ValueError):
            return None

    def _app_alive(self, meta: dict | None) -> bool:
        if not meta:
            return False
        try:
            os.kill(int(meta["pid"]), 0)
            return True
        except (OSError, KeyError, ValueError):
            return False

    def launch(self, window: bool = False) -> None:
        """Start the capture helper: hidden (no window, no Dock icon) unless window=True."""
        if not APP.exists():
            raise RigError(f"{APP} is missing. Build it with: ./scripts/build-app.sh")
        if not window and AGENT_PLIST.exists():
            if not _agent_loaded():
                subprocess.run(["launchctl", "bootstrap", _domain(), str(AGENT_PLIST)], check=False)
            subprocess.run(["launchctl", "kickstart", f"{_domain()}/{AGENT_LABEL}"], check=False)
            return
        args = ["open", "-g", "-j", str(APP), "--args", "run", str(self.dir), "--fps", str(self.fps)]
        if window:
            args = ["open", str(APP), "--args", "run", str(self.dir), "--fps", str(self.fps), "--window"]
        subprocess.run(args, check=True)

    def stop(self) -> None:
        """Stop the helper. With autostart on it stays stopped until `rig start` or the next login."""
        if _agent_loaded():
            subprocess.run(["launchctl", "bootout", f"{_domain()}/{AGENT_LABEL}"], check=False)
        subprocess.run(["pkill", "-f", "iPhone Rig.app/Contents/MacOS/iphone-rig"])
        subprocess.run(["pkill", "-f", "vendor/UxPlay/build/uxplay"])

    # ---- autostart at login (a per-user LaunchAgent) ----

    def autostart(self, on: bool) -> None:
        if not on:
            self.stop()
            AGENT_PLIST.unlink(missing_ok=True)
            return
        if not APP.exists():
            raise RigError(f"{APP} is missing. Build it with: ./scripts/build-app.sh")
        self.stop()
        AGENT_PLIST.parent.mkdir(parents=True, exist_ok=True)
        with open(AGENT_PLIST, "wb") as f:
            plistlib.dump({
                "Label": AGENT_LABEL,
                "ProgramArguments": [str(APP / "Contents/MacOS/iphone-rig"), "run", str(self.dir), "--fps", str(self.fps)],
                "RunAtLoad": True,
                "KeepAlive": True,          # restart it if it ever quits
                "ThrottleInterval": 10,
                "StandardErrorPath": str(self.dir / "helper.log"),
            }, f)
        subprocess.run(["launchctl", "bootstrap", _domain(), str(AGENT_PLIST)], check=True)


    def ensure_running(self, timeout: float = 20.0) -> dict:
        meta = self._meta()
        if _fresh(meta):
            return meta
        if not self._app_alive(meta) and not self._process_running():
            self.launch()
        deadline = time.time() + timeout
        while time.time() < deadline:
            meta = self._meta()
            if _fresh(meta):
                return meta
            time.sleep(0.2)
        status = self._status()
        if status and not status.startswith("Waiting"):
            raise RigError(f"No fresh iPhone frames. {status}")
        raise RigError(
            "No fresh iPhone frames. Mirror the iPhone to the Mac: on the iPhone, Control Center > "
            "Screen Mirroring > Claude Rig (Mac and iPhone on the same Wi-Fi). The USB cable also "
            "works when iOS allows it. The iPhone must be unlocked."
        )

    def _status(self) -> str:
        """The running helper's status line, e.g. that the iPhone connected but sends no picture."""
        try:
            s = json.loads((self.dir / "status.json").read_text())
        except (OSError, ValueError):
            return ""
        return s.get("status", "") if self._app_alive(s) else ""

    def frame_age(self) -> float:
        """Seconds since the screen last changed (the newest frame arrived)."""
        meta = self._meta() or {}
        return max(0.0, time.time() - meta.get("time", time.time()))

    def _process_running(self) -> bool:
        r = subprocess.run(["pgrep", "-f", "iPhone Rig.app/Contents/MacOS/iphone-rig"], capture_output=True)
        return r.returncode == 0

    # ---- frames ----

    def frame(self) -> tuple[Image.Image, dict]:
        """Latest frame as a PIL image (full resolution) plus its metadata."""
        self.ensure_running()
        for _ in range(10):
            try:
                data = (self.dir / "latest.jpg").read_bytes()
                img = Image.open(BytesIO(data))
                img.load()
                return img, self._meta() or {}
            except (OSError, ValueError):
                time.sleep(0.05)
        raise RigError("Could not read the latest frame.")

    def frame_after(self, t: float, timeout: float = 3.0) -> tuple[Image.Image, dict]:
        """A frame captured after time t (so it shows the result of an action)."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            meta = self._meta()
            if meta and meta["time"] > t:
                break
            time.sleep(0.05)
        return self.frame()

    def wait_still(self, timeout: float = 4.0, settle: float = 0.5, threshold: float = 1.5) -> Image.Image:
        """Wait until the screen stops changing (animations done), then return the frame."""
        start = time.time()
        prev, _ = self.frame()
        prev_small = _small(prev)
        still_since = None
        last_frame_no = None
        while time.time() - start < timeout:
            time.sleep(1.0 / max(self.fps, 1))
            img, meta = self.frame()
            if meta.get("frame") == last_frame_no:
                continue
            last_frame_no = meta.get("frame")
            small = _small(img)
            diff = float(np.abs(small - prev_small).mean())
            prev_small = small
            if diff < threshold:
                still_since = still_since or time.time()
                if time.time() - still_since >= settle:
                    return img
            else:
                still_since = None
        return self.frame()[0]

    # ---- marker shown in the viewer window ----

    def mark(self, x: float | None, y: float | None, label: str) -> None:
        data = {"x": x if x is not None else -100, "y": y if y is not None else -100,
                "label": label, "time": time.time()}
        tmp = self.dir / "marker.json.tmp"
        tmp.write_text(json.dumps(data))
        os.replace(tmp, self.dir / "marker.json")


def _fresh(meta: dict | None, max_age: float = 2.0) -> bool:
    """The helper writes `alive` while the source is streaming, even when the screen is still."""
    if not meta:
        return False
    return time.time() - meta.get("alive", meta.get("time", 0)) < max_age


def _small(img: Image.Image) -> np.ndarray:
    return np.asarray(img.convert("L").resize((90, 195)), dtype=np.float32)


def find_pointer(before: Image.Image, after: Image.Image, avoid: tuple[float, float] | None = None,
                 min_px: int = 4) -> tuple[float, float] | None:
    """Find the AssistiveTouch pointer that appeared between two frames.

    Returns the centre (full-resolution pixels) of the changed blob farthest from `avoid`
    (the old pointer position), or None if nothing changed.
    """
    scale = 4
    w, h = before.size
    a = np.asarray(before.convert("L").resize((w // scale, h // scale)), dtype=np.int16)
    b = np.asarray(after.convert("L").resize((w // scale, h // scale)), dtype=np.int16)
    mask = np.abs(a - b) > 25
    if mask.sum() < min_px:
        return None
    blobs = _blobs(mask)
    blobs = [bl for bl in blobs if len(bl[0]) >= min_px]
    if not blobs:
        return None

    def centre(bl):
        ys, xs = bl
        return float(xs.mean() * scale), float(ys.mean() * scale)

    centres = [centre(bl) for bl in blobs]
    if avoid is None:
        return max(centres, key=lambda c: c[0] + c[1])
    return max(centres, key=lambda c: (c[0] - avoid[0]) ** 2 + (c[1] - avoid[1]) ** 2)


def locate_pointer(before: Image.Image, after: Image.Image, expect: tuple[float, float],
                   radius: float = 300.0, scale: int = 4) -> tuple[float, float] | None:
    """Where the pointer is in `after`: the changed blob nearest `expect` (full-res pixels).

    Blobs far from `expect`, tiny ones (noise) and huge ones (the whole screen changed)
    are ignored. Returns None when no blob qualifies.
    """
    w, h = before.size
    if after.size != before.size:
        return None
    a = np.asarray(before.convert("L").resize((w // scale, h // scale)), dtype=np.int16)
    b = np.asarray(after.convert("L").resize((w // scale, h // scale)), dtype=np.int16)
    mask = np.abs(a - b) > 25
    if mask.sum() < 4 or mask.mean() > 0.25:
        return None
    best, best_d = None, radius
    for ys, xs in _blobs(mask):
        n = len(xs)
        if n < 4 or n > 4000:
            continue
        c = (float(xs.mean() * scale), float(ys.mean() * scale))
        d = ((c[0] - expect[0]) ** 2 + (c[1] - expect[1]) ** 2) ** 0.5
        if d < best_d:
            best, best_d = c, d
    return best


def _blobs(mask: np.ndarray):
    """Connected components of a boolean mask (4-neighbour), as (ys, xs) index arrays."""
    seen = np.zeros_like(mask, dtype=bool)
    out = []
    H, W = mask.shape
    for y0, x0 in zip(*np.nonzero(mask)):
        if seen[y0, x0]:
            continue
        stack = [(y0, x0)]
        seen[y0, x0] = True
        ys, xs = [], []
        while stack:
            y, x = stack.pop()
            ys.append(y); xs.append(x)
            for ny, nx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
                if 0 <= ny < H and 0 <= nx < W and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    stack.append((ny, nx))
        out.append((np.array(ys), np.array(xs)))
    return out
