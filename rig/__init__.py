"""iPhone rig: Claude sees the iPhone over the cable and taps it through an ESP32."""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RIG_DIR = ROOT / ".rig"                      # frames, marker, logs
APP = ROOT / "build" / "iPhone Rig.app"      # viewer + capture app
CALIBRATION = ROOT / "calibration.json"


class RigError(RuntimeError):
    """A problem the user can fix (cable, permission, board, pairing)."""
