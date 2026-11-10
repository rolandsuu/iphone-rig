"""MCP server: lets Claude Code see and control the iPhone.

Register once:
  claude mcp add iphone --scope user -- uv run --directory ~/iphone-rig iphone-rig-mcp
"""

from __future__ import annotations

import time

from mcp.server.fastmcp import FastMCP, Image

from .control import Rig

INSTRUCTIONS = """\
These tools control the user's real iPhone 12 mini. Its screen comes over AirPlay or the Lightning cable;
taps and typing go through an ESP32 that acts as a Bluetooth mouse and keyboard.

- Start with `screenshot`. Coordinates for every tool are pixels in the latest screenshot
  (400 px wide). Each action returns a fresh screenshot after the screen settles.
- Taps go through a mouse pointer, so they can land a few pixels off. Aim at the centre of
  buttons, and check the next screenshot before continuing. The grey circle in screenshots is
  that pointer (AssistiveTouch), not part of the app.
- `type_text` only types ASCII. For Chinese, type the pinyin and tap the candidate.
- Ask the user before paying, placing orders, sending messages, posting, or deleting anything.
  Never enter passwords or payment PINs; ask the user to do it on the phone.
"""

mcp = FastMCP("iphone", instructions=INSTRUCTIONS)
_rig: Rig | None = None


def rig() -> Rig:
    global _rig
    if _rig is None:
        _rig = Rig()
    return _rig


def _stale_note() -> str:
    """A warning when the screen hasn't changed for a while.

    AirPlay sends a frame only when the screen changes, and the status-bar clock changes every
    minute, so a long-unchanged screen usually means the feed is stuck (full-screen apps
    without a status bar are the exception).
    """
    age = rig().eyes.frame_age()
    if age < 90:
        return ""
    since = time.strftime("%H:%M", time.localtime(time.time() - age))
    ago = f"{age / 3600:.1f} h" if age >= 3600 else f"{age / 60:.0f} min"
    return (f" Warning: the screen has not changed since {since} ({ago} ago). If the clock in the "
            "status bar is behind, the feed is stuck: ask the user to unlock the iPhone and "
            "re-mirror it to Claude Rig.")


def _after(note: str, t0: float | None = None) -> list:
    r = rig()
    if t0 is not None:
        r.eyes.frame_after(t0)
    data, w, h = r.screenshot(settle=t0 is not None)
    return [f"{note} Screenshot is {w}x{h}.{_stale_note()}", Image(data=data, format="jpeg")]


@mcp.tool()
def screenshot() -> list:
    """Show the iPhone screen right now."""
    return _after("Current iPhone screen.")


@mcp.tool()
def tap(x: int, y: int) -> list:
    """Tap at (x, y) in screenshot pixels."""
    t0 = time.time()
    rig().tap(x, y)
    return _after(f"Tapped ({x}, {y}).", t0)


@mcp.tool()
def long_press(x: int, y: int, seconds: float = 0.8) -> list:
    """Press and hold at (x, y) in screenshot pixels."""
    t0 = time.time()
    rig().tap(x, y, hold_ms=int(seconds * 1000))
    return _after(f"Long-pressed ({x}, {y}) for {seconds}s.", t0)


@mcp.tool()
def swipe(x1: int, y1: int, x2: int, y2: int) -> list:
    """Drag from (x1, y1) to (x2, y2) in screenshot pixels, like a finger swipe."""
    t0 = time.time()
    rig().swipe(x1, y1, x2, y2)
    return _after(f"Swiped ({x1}, {y1}) -> ({x2}, {y2}).", t0)


@mcp.tool()
def scroll(x: int, y: int, amount: int) -> list:
    """Scroll with the mouse wheel over (x, y). Positive amount scrolls up, negative down (try 5 to 20)."""
    t0 = time.time()
    rig().scroll(x, y, amount)
    return _after(f"Scrolled {amount} at ({x}, {y}).", t0)


@mcp.tool()
def type_text(text: str) -> list:
    """Type ASCII text into the focused field. Use \\n for Return."""
    t0 = time.time()
    rig().type_text(text)
    return _after(f"Typed {len(text)} characters.", t0)


@mcp.tool()
def press_key(combo: str) -> list:
    """Press a key or combo, e.g. enter, backspace, esc, tab, up, down, cmd+space, cmd+a."""
    t0 = time.time()
    rig().key(combo)
    return _after(f"Pressed {combo}.", t0)


@mcp.tool()
def go_home() -> list:
    """Press the Home key. If the next screenshot still shows an overlay (e.g. Search), call it again."""
    t0 = time.time()
    rig().home()
    return _after("Pressed Home.", t0)


@mcp.tool()
def rig_status() -> str:
    """Check the screen feed (AirPlay or cable), the ESP32 board, Bluetooth pairing and calibration."""
    r = rig()
    lines = []
    try:
        w, h = r.frame_size()
        source = (r.eyes._meta() or {}).get("source", "usb")
        lines.append(f"screen feed: ok ({w}x{h}, via {'AirPlay' if source == 'airplay' else 'USB cable'})")
    except Exception as e:  # noqa: BLE001
        lines.append(f"screen feed: {e}")
    try:
        s = r.hands.status()
        lines.append(f"board: ok on {s.get('port')}, bluetooth connected={s.get('connected')}")
    except Exception as e:  # noqa: BLE001
        lines.append(f"board: {e}")
    lines.append(f"calibrated: {r.cal.get('calibrated')} ({r.cal.get('calibrated_at', 'never')})")
    return "\n".join(lines)


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
