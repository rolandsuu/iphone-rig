"""Hands: the ESP32 Bluetooth mouse + keyboard, driven over USB serial."""

from __future__ import annotations

import glob
import os
import sys
import time

from . import RigError

PORT_PATTERNS = ["/dev/cu.wchusbserial*", "/dev/cu.usbmodem*", "/dev/cu.usbserial*", "/dev/cu.SLAB_USBtoUART*"]


class Hands:
    def __init__(self, port: str | None = None, baud: int = 115200, dry_run: bool | None = None):
        self.dry_run = os.environ.get("RIG_DRY_RUN") == "1" if dry_run is None else dry_run
        self.port_name = port or os.environ.get("RIG_PORT")
        self.baud = baud
        self.ser = None

    # ---- connection ----

    def _open(self, name: str):
        import serial  # pyserial

        s = serial.Serial(name, self.baud, timeout=0.2)
        time.sleep(0.1)
        s.reset_input_buffer()
        return s

    def connect(self) -> None:
        if self.dry_run or self.ser:
            return
        candidates = [self.port_name] if self.port_name else sorted({p for pat in PORT_PATTERNS for p in glob.glob(pat)})
        if not candidates:
            raise RigError("The ESP32 board is not plugged in (no USB serial port found). "
                           "Connect it to the Mac with the USB-C cable.")
        errors = []
        for name in candidates:
            try:
                s = self._open(name)
                s.write(b"PING\n")
                if self._read_reply(s, 2.0).startswith("OK PONG"):
                    self.ser = s
                    self.port_name = name
                    return
                s.close()
            except Exception as e:  # noqa: BLE001
                errors.append(f"{name}: {e}")
        raise RigError("Found serial ports but none answered as the rig board. "
                       "Is the firmware flashed? " + "; ".join(errors))

    @staticmethod
    def _read_reply(s, timeout: float) -> str:
        deadline = time.time() + timeout
        while time.time() < deadline:
            line = s.readline().decode(errors="replace").strip()
            if not line or line.startswith("EVENT"):
                continue
            return line
        return ""

    # ---- commands ----

    def cmd(self, line: str, timeout: float = 15.0) -> str:
        if self.dry_run:
            print(f"[dry-run] {line}", file=sys.stderr)
            return "OK x=0 y=0 connected=1"
        self.connect()
        self.ser.reset_input_buffer()
        self.ser.write((line.strip() + "\n").encode())
        reply = self._read_reply(self.ser, timeout)
        if not reply:
            raise RigError(f"The board did not answer '{line.split()[0]}'.")
        if reply.startswith("ERR"):
            msg = reply[3:].strip()
            if "not connected" in msg:
                msg += (". Pair it: iPhone Settings > Bluetooth > Claude Rig, and turn on "
                        "Settings > Accessibility > Touch > AssistiveTouch.")
            raise RigError(msg)
        return reply

    def status(self) -> dict:
        reply = self.cmd("STATUS")
        out = {}
        for part in reply.split()[1:]:
            if "=" in part:
                k, v = part.split("=", 1)
                out[k] = int(v) if v.lstrip("-").isdigit() else v
        out["port"] = self.port_name
        return out

    def configure(self, step: int, delay_ms: int) -> None:
        self.cmd(f"CFG {step} {delay_ms}")

    def corner(self) -> None:
        self.cmd("CORNER")

    def move(self, dx: int, dy: int) -> None:
        self.cmd(f"MOVE {dx} {dy}")

    def move_to(self, x: int, y: int) -> None:
        self.cmd(f"MOVETO {x} {y}")

    def tap(self, x: int, y: int, hold_ms: int = 50) -> None:
        self.cmd(f"TAP {x} {y} {hold_ms}")

    def click(self, hold_ms: int = 50) -> None:
        """Press and release where the pointer is now."""
        self.cmd(f"CLICK {hold_ms}")

    def down(self) -> None:
        self.cmd("DOWN")

    def up(self) -> None:
        self.cmd("UP")

    def scroll(self, n: int) -> None:
        self.cmd(f"SCROLL {n}")

    def type(self, text: str) -> str:
        if any(ord(c) > 126 or (ord(c) < 32 and c not in "\n\t") for c in text):
            raise RigError("Only ASCII text can be typed. For Chinese, type the pinyin and tap the "
                           "candidate on screen.")
        out = ""
        for i in range(0, len(text), 200):   # keep serial lines short
            out = self.cmd("TYPE " + text[i:i + 200], timeout=60)
        return out

    def key(self, combo: str) -> None:
        self.cmd(f"KEY {combo}")

    def consumer(self, usage: int) -> None:
        self.cmd(f"CONSUMER {usage}")
