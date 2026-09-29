#!/usr/bin/env python3
"""Build the FXMic startup script for the EP-2350 by patching Teenage Engineering's own startup script.

TE's script is copyrighted and is not part of this repository. It is read from YOUR mic (its /rom/main.py) over
the serial console, or from a local copy you extracted yourself, and our additions are inserted:
handle press/release markers, shake-to-cancel, and a play button pinned to slot 1.

usage:
  tools/build_fxmic_script.py --from-device          # mic on USB-C, reads /rom/main.py over the console
  tools/build_fxmic_script.py --from-file path/to/te_main.py
Writes firmware/fxmic/main.py (git-ignored). Then: tools/install_disk.sh install
"""
import os, sys

ADDITIONS = '# ---- fxmic additions: play a marker sample when the handle is squeezed and another when it is released ----\nHANDLE_ON = 0.5         # ui.handle() units, set from the probe so a light touch does not count\nHANDLE_OFF = 0.3\nPRESS_SLOT = 2          # press.wav\nRELEASE_SLOT = 3        # release.wav\nCANCEL_SLOT = 1         # cancel.wav, played once per squeeze when the mic is shaken\nONE_G = 17400           # accelerometer counts at rest (probe: 17000-17900). Rotating the mic keeps the magnitude here.\nSHAKE_DEV = 7000        # excursion from one g that counts (about 0.4 g)\nSHAKE_EXCURSIONS = 3    # alternating above/below excursions needed: a shake oscillates, a gesture does not\nSHAKE_WINDOW = 30       # ticks (about 550 ms)\nhandle_down = False\nhandle_count = 0\nmarker_release = -1     # slot whose trigger is released on the next tick\nexcursions = []         # (tick, sign) of alternating excursions\ntick_no = 0\ncanceled_this_squeeze = False\n\ndef shake_update():\n    global excursions, tick_no, canceled_this_squeeze, marker_release\n    tick_no += 1\n    if not handle_down:\n        excursions = []\n        return\n    a = ui.acc()\n    d = int((a[0]*a[0] + a[1]*a[1] + a[2]*a[2]) ** 0.5) - ONE_G\n    if d > SHAKE_DEV or d < -SHAKE_DEV:\n        sgn = 1 if d > 0 else -1\n        if not excursions or excursions[-1][1] != sgn:\n            excursions.append((tick_no, sgn))\n    excursions = [e for e in excursions if tick_no - e[0] <= SHAKE_WINDOW]\n    if len(excursions) >= SHAKE_EXCURSIONS and not canceled_this_squeeze:\n        canceled_this_squeeze = True\n        excursions = []\n        spl.trigger(-1, CANCEL_SLOT, True)\n        marker_release = CANCEL_SLOT\n\ndef handle_update(v):\n    global handle_down, handle_count, marker_release, canceled_this_squeeze\n    if (not handle_down) and v > HANDLE_ON:\n        handle_count += 1\n        if handle_count >= 2:\n            handle_down = True\n            handle_count = 0\n            canceled_this_squeeze = False\n            spl.trigger(-1, PRESS_SLOT, True)\n            marker_release = PRESS_SLOT\n    elif handle_down and v < HANDLE_OFF:\n        handle_count += 1\n        if handle_count >= 2:\n            handle_down = False\n            handle_count = 0\n            spl.trigger(-1, RELEASE_SLOT, True)\n            marker_release = RELEASE_SLOT\n    else:\n        handle_count = 0\n# ---- end fxmic additions ----\n'

def patch(original: str) -> str:
    s = original
    def replace_once(old, new, what):
        nonlocal s
        if old not in s:
            sys.exit(f"cannot find the {what} in TE's script; firmware layout changed, see PLAN.md")
        s = s.replace(old, new, 1)
    replace_once("def python_callback(message):\n    #print(f\"callback {message:08x}\")",
                 ADDITIONS + "\ndef python_callback(message):\n    global handle_down, handle_count, marker_release, canceled_this_squeeze\n    #print(f\"callback {message:08x}\")",
                 "callback definition")
    replace_once("                sam_pos = sam_pos + 1\n                if sam_pos >= 4:\n                    sam_pos = 0\n                ui.leds(fx_pos,sam_pos)",
                 "                sam_pos = sam_pos + 1\n                if sam_pos >= 1:        # fxmic: slots 2-4 are markers (cancel, press, release); the play button stays on slot 1\n                    sam_pos = 0\n                ui.leds(fx_pos,sam_pos)",
                 "sample select cycling")
    replace_once("    if mess_type == 3:\n        if fx_primed > 0:",
                 "    if mess_type == 3:\n        handle_update(ui.handle())\n        shake_update()\n        if marker_release >= 0:\n            spl.trigger(-1, marker_release, False)\n            marker_release = -1\n        if fx_primed > 0:",
                 "tick handler")
    return s

def main():
    args = sys.argv[1:]
    here = os.path.dirname(os.path.abspath(__file__))
    if args[:1] == ["--from-file"] and len(args) == 2:
        original = open(args[1]).read()
    elif args[:1] == ["--from-device"]:
        sys.path.insert(0, here)
        from mp_exec import open_port, raw_exec
        fd = open_port()
        out, err = raw_exec(fd, "f=open('/rom/main.py')\nwhile True:\n b=f.read(512)\n if not b: break\n print(b, end='')\nf.close()", 30)
        os.close(fd)
        if out is None or (err and err.strip()): sys.exit(f"could not read /rom/main.py from the mic: {err}")
        original = out
    else:
        sys.exit(__doc__)
    patched = patch(original)
    dst = os.path.join(here, "..", "firmware", "fxmic", "main.py")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    open(dst, "w").write(patched)
    print(f"wrote {os.path.relpath(dst)} ({len(patched)} bytes) from a {len(original)}-byte original")

if __name__ == "__main__":
    main()
