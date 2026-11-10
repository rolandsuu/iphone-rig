# iPhone Rig

Lets Claude Code see and control your iPhone 12 mini.

- **Eyes:** `iPhone Rig.app` runs as a hidden background helper (no window, no Dock icon) and saves the latest frame for Claude. Over AirPlay it saves every frame as it arrives (AirPlay sends one only when the screen changes); over the cable it re-encodes only when a thumbnail check sees a change, to ignore the cable's noise. Claude's iPhone tools start it if it isn't running. It takes the screen from either:
  - **AirPlay (main route):** the helper runs [UxPlay](https://github.com/FDH2/UxPlay) hidden as an AirPlay receiver called **Claude Rig**. On the iPhone: Control Center → Screen Mirroring → Claude Rig. No window opens on the Mac.
  - **Lightning cable:** macOS iPhone screen capture over USB. Used automatically when iOS allows it (it stopped working on 2026-11-09: iOS never answers the stream request, "valeria connection not seen").
- **Hands:** an ESP32-S3 pairs with the iPhone as a Bluetooth mouse + keyboard ("Claude Rig"). The Mac sends it commands over its USB-C cable.
- **Brain:** Claude Code uses the `iphone` MCP server (`rig/server.py`): `screenshot`, `tap`, `long_press`, `swipe`, `scroll`, `type_text`, `press_key`, `go_home`, `rig_status`.

```
iPhone ──AirPlay (Wi-Fi) or Lightning cable──▶ Mac: iPhone Rig.app ──frames──▶ MCP server ◀──▶ Claude Code
iPhone ◀──Bluetooth── ESP32 ◀──USB-C cable── Mac: MCP server
```

## Screen over AirPlay

1. Build UxPlay once (needs `brew install cmake pkgconf libplist gstreamer`):
   ```bash
   ./scripts/build-uxplay.sh
   ```
2. Start the helper (`uv run rig start`). It starts UxPlay, which shows up on the iPhone as **Claude Rig**. It uses ports 7700–7702, so the Mac's own AirPlay Receiver can stay on.
3. On the iPhone: Control Center → **Screen Mirroring** → **Claude Rig**. Pick Claude Rig, not the Mac's own name: the Mac's built-in receiver takes over the whole screen.
4. The first time, macOS may ask whether `uxplay` may accept incoming network connections, or whether iPhone Rig may find devices on your local network. Allow both.

Mac and iPhone must be on the same Wi-Fi. The helper logs connections to `.rig/helper.log` when started with `open --stderr`.

Status 2026-11-09: everything works end to end over AirPlay: screen 1080×2340 at about 0.1 s delay, ESP32 flashed and paired, pointer calibrated, taps land within a few pixels, Home key works.

## Tomorrow: set up the ESP32 (about 15 minutes)

1. **Flash the firmware.** Plug the ESP32 into the Mac. On boards with two USB-C ports, use the one labelled **COM** (or UART). Then:
   ```bash
   cd ~/iphone-rig/firmware && ~/.local/bin/pio run -t upload
   ```
   If it can't connect: hold **BOOT**, tap **RST**, let go of BOOT, and run it again.
   To use the port labelled **USB** instead, change `ARDUINO_USB_CDC_ON_BOOT=0` to `1` in `firmware/platformio.ini` and upload again.
2. **Pair with the iPhone:** Settings → Bluetooth → **Claude Rig** → Pair.
3. **iPhone settings** (Settings → Accessibility):
   - Touch → AssistiveTouch: **on**. Under Pointer Devices, turn **Auto-Hide off**, and leave Tracking Speed alone after calibrating.
   - Touch → AssistiveTouch: turn **Always Show Menu off**, so the floating button doesn't cover things.
   - Motion → **Reduce Motion on** (faster, steadier screenshots).
   - Display & Brightness → Auto-Lock: **Never** while the rig runs.
4. **Check everything:**
   ```bash
   cd ~/iphone-rig && uv run rig status
   ```
   You want: screen feed ok, board ok, bluetooth connected=1.
5. **Calibrate** with the iPhone mirroring to Claude Rig and on its home screen:
   ```bash
   uv run rig calibrate
   ```
   It moves the pointer 150 counts at a time, watches where it goes, and saves `calibration.json`. The numbers only aim the first move: every tap then finds the pointer in the screen feed and corrects the rest (closed loop).
6. **Test a tap.** Coordinates are pixels in the 400-px-wide screenshot:
   ```bash
   uv run rig snap /tmp/s.jpg
   ```
   ```bash
   uv run rig tap 200 430
   ```
7. **Use it from Claude Code.** Start a new session and ask, for example, "open WeChat on my iPhone and search for 麦稻".

## Commands

| Command | What it does |
|---|---|
| `uv run rig autostart on` / `off` | start the hidden helper at every login and restart it if it quits (a per-user LaunchAgent) |
| `uv run rig start` / `stop` | start or stop the hidden capture helper now |
| `uv run rig window` | debug only: the standalone viewer window |
| `uv run rig status` | screen feed, board, Bluetooth, calibration |
| `uv run rig snap out.jpg` | the same screenshot Claude sees |
| `uv run rig calibrate` | measure pointer movement |
| `uv run rig tap X Y` / `swipe X1 Y1 X2 Y2` / `home` | pointer actions |
| `uv run rig type "text"` / `key cmd+space` | keyboard |
| `uv run rig raw "MOVE 100 0"` | raw firmware command (see `firmware/src/main.cpp`) |
| `uv run rig --dry-run tap 200 400` | print the board commands without a board |

## Keep the helper running

`uv run rig start` runs it in the background until you log out or restart. To have it start at every login, run this yourself once:

```bash
cd ~/iphone-rig && uv run rig autostart on
```

`uv run rig autostart off` undoes it. Debug only: `uv run rig window` shows the old standalone window, and `--preview` makes the helper also write 720-px strips (for a side pane).

## Rebuild the viewer app

```bash
./scripts/build-app.sh
```

macOS asks once for Camera access for **iPhone Rig**. That is how it reads the iPhone screen; the audio track is ignored.

## Limits

- Taps go through a mouse pointer. iOS pointer acceleration is not linear, so each tap moves, finds the pointer in the feed, and corrects up to twice (lands within about 4–12 px of a 400-px screenshot). The rig also re-anchors in the top-left corner every few actions (`recorner_every` in `calibration.json`).
- Typing is ASCII only. For Chinese, type pinyin and tap the candidate.
- `go_home` sends the Bluetooth keyboard's Home key (HID consumer 0x223). A pointer swipe up from the bottom opens the App Switcher instead. From an overlay such as Search, press Home twice.
- UxPlay decodes video in software (`avdec_h264`, one thread): the hardware decoder held each final frame until the next one arrived, so screenshots showed the screen one action late.
- The iPhone must stay unlocked and mirroring (or plugged in, for the cable route). Claude asks before paying, ordering, sending or deleting.
- AirPlay adds roughly 0.2–0.5 s of delay, and the phone stops mirroring if it locks or leaves the Wi-Fi.
- The iPhone can connect to Claude Rig and send no picture (seen 2026-11-10 after an overnight reconnect: UxPlay never logged "Begin streaming"). The helper counts the feed as live only after a frame arrives in the current connection, so the tools say "connected but sends no picture" instead of serving an old frame. Fix it on the iPhone: stop Screen Mirroring and pick Claude Rig again.
- AirPlay sends a frame only when the screen changes, and the status-bar clock changes every minute. So when the screen hasn't changed for 90 s, `screenshot` adds a warning that the feed may be stuck. Full-screen apps without a status bar can trigger it falsely.
