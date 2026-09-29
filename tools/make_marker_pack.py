#!/usr/bin/env python3
"""Marker pack for the custom script: slot 1 tap chirp, slot 2 cancel marker (shake), slot 3 press marker, slot 4 release marker. All one-shot, all dry."""
import json, math, os, struct, wave
SR = 48000
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "packs", "marker-pack")
os.makedirs(OUT, exist_ok=True)
def burst(freqs, dur=0.12, amp=0.35, fade=0.005):
    n, nf = int(dur * SR), int(fade * SR); out = []
    for i in range(n):
        env = 0.5 - 0.5 * math.cos(math.pi * i / nf) if i < nf else (0.5 - 0.5 * math.cos(math.pi * (n - i) / nf) if i > n - nf else 1.0)
        out.append(sum(math.sin(2 * math.pi * f * i / SR) for f in freqs) * amp * env)
    return out
def write(name, samples):
    with wave.open(os.path.join(OUT, name), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in samples))
write("chirp.wav", burst([15500, 16500]))      # tap
write("press.wav", burst([17000, 18500]))      # handle squeezed
write("release.wav", burst([14000, 15000]))    # handle released
write("cancel.wav", burst([12000, 13000]))     # shake while squeezed
config = {
    "name": "CLAUDE MARKERS",
    "samples": [
        {"pos": 0, "file": "chirp.wav", "playmode": "oneshot"},
        {"pos": 1, "file": "cancel.wav", "playmode": "oneshot"},
        {"pos": 2, "file": "press.wav", "playmode": "oneshot"},
        {"pos": 3, "file": "release.wav", "playmode": "oneshot"},
    ],
    "presets": [{"pos": p, "list": [{"effect": "SAMPLE", "level": 1.0}], "trigger": {"row": 0}} for p in range(4)],
}
json.dump(config, open(os.path.join(OUT, "config.json"), "w"), indent=1)
print("marker-pack:", sorted(os.listdir(OUT)))
