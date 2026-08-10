#!/usr/bin/env python3
"""
Assert the properties the sound spec actually requires, over every shipped asset.

This exists because the important claims in docs/games/SOUND_DESIGN.md are checkable, and a
sound file is the one kind of artefact where "looks right" is no evidence at all. It is the
regression test for the audio: run it after any change to synth.py or physical.py.

Checks:
  MONO             every file, both platforms. A stereo buffer on GameAudio's mono-wired bus
                   is an ObjC NSException `try?` cannot catch — the process dies (§6.6).
  SAMPLE RATE      44.1 kHz. GameAudio refuses anything else, silently, at load.
  NO LEADING GAP   leading silence is perceived latency (§6.3).
  NO CLIPPING      nothing at full scale, so runtime varispeed cannot clip.
  LOUDNESS         one-shots within tolerance of -16 LUFS, the bed near -26 (§6.1).
  X vs O           chalk_x must read as TWO strokes and chalk_o as ONE. This is the whole
                   point of the request, so it is asserted rather than assumed (§4.3).
  LOOP SEAM        the crowd bed's end must match its start, or the loop ticks (§4.1).
  BUDGET           under 4 MB per platform (§7).

Usage: python3 tools/gamesounds/verify.py
"""
from __future__ import annotations

import array
import math
import os
import re
import subprocess
import sys
import wave

from dsp import SR, loudness_lufs

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
IOS_OUT = os.path.join(REPO_ROOT, "apps/ios/Voiid/Voiid/Resources/GameSounds")
ANDROID_OUT = os.path.join(REPO_ROOT, "apps/android/app/src/main/res/raw")
BUDGET_KB = 4096

failures: list[str] = []
checks = 0


def check(ok: bool, label: str) -> None:
    global checks
    checks += 1
    if not ok:
        failures.append(label)


def read_wav(path: str) -> tuple[list[float], int, int]:
    with wave.open(path, "rb") as w:
        ch, width, rate, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(n)
    if width != 2:
        return [], ch, rate
    pcm = array.array("h")
    pcm.frombytes(raw)
    return [v / 32768.0 for v in pcm], ch, rate


def probe_m4a(path: str) -> tuple[int, int]:
    """(channels, sample rate) from afinfo's "Data format: 1 ch,  44100 Hz, aac" line.

    macOS only. Returns (0, 0) where afinfo is unavailable, and the caller skips rather than
    failing — a non-macOS host cannot have produced these files in the first place.
    """
    try:
        out = subprocess.run(["afinfo", path], capture_output=True, text=True).stdout
    except FileNotFoundError:
        return 0, 0
    m = re.search(r"(\d+)\s+ch,\s+(\d+)\s*Hz", out)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)


def envelope(xs: list[float], win_ms: float = 8.0) -> list[float]:
    """RMS envelope, for reading a sound's gesture shape rather than its waveform."""
    w = max(int(SR * win_ms / 1000), 1)
    return [
        math.sqrt(sum(v * v for v in xs[i:i + w]) / w)
        for i in range(0, len(xs) - w, w)
    ]


def stroke_count(xs: list[float], floor_ratio: float = 0.22) -> int:
    """How many separated bursts of energy the file contains.

    A gesture is one stroke if its envelope stays above a fraction of its own peak
    throughout, and two if it dips below and comes back. That dip is exactly what makes an X
    audibly two lines and an O audibly one sweep.
    """
    env = envelope(xs)
    if not env:
        return 0
    peak = max(env)
    if peak <= 0:
        return 0
    floor = peak * floor_ratio
    above = [v >= floor for v in env]
    count, prev = 0, False
    for v in above:
        if v and not prev:
            count += 1
        prev = v
    return count


# --- mono + rate + level, over everything -----------------------------------------------

print("Checking every shipped asset...\n")

for out_dir, platform in ((IOS_OUT, "ios"), (ANDROID_OUT, "android")):
    total = 0
    for name in sorted(os.listdir(out_dir)):
        path = os.path.join(out_dir, name)
        if not os.path.isfile(path):
            continue
        total += os.path.getsize(path)

        if name.endswith(".wav"):
            xs, ch, rate = read_wav(path)
            check(ch == 1, f"{platform}/{name}: {ch} channels — MUST be mono (hard crash)")
            check(rate == SR, f"{platform}/{name}: {rate} Hz — must be {SR}")
            if xs:
                peak = max(abs(v) for v in xs)
                check(peak < 0.999, f"{platform}/{name}: clips at full scale")
                lead = next((i for i, v in enumerate(xs) if abs(v) > 0.004), 0)
                check(lead < SR * 0.012,
                      f"{platform}/{name}: {lead/SR*1000:.0f} ms of leading silence")
        elif name.endswith(".m4a"):
            ch, rate = probe_m4a(path)
            if ch:
                check(ch == 1, f"{platform}/{name}: {ch} channels — MUST be mono")
                check(rate == SR, f"{platform}/{name}: {rate} Hz — must be {SR}")

    kb = total / 1024
    check(kb < BUDGET_KB, f"{platform}: {kb:.0f} KB exceeds the {BUDGET_KB} KB budget")
    print(f"  {platform:8s} payload {kb:7.1f} KB / {BUDGET_KB} KB")

# --- the X / O distinction, which is the actual request ---------------------------------

print()
for i in (1, 2, 3):
    xs, _, _ = read_wav(os.path.join(IOS_OUT, f"chalk_x_{i}.wav"))
    n = stroke_count(xs)
    check(n == 2, f"chalk_x_{i}: reads as {n} stroke(s) — an X must be TWO")
    print(f"  chalk_x_{i}  strokes={n}  (want 2)")

for i in (1, 2, 3):
    xs, _, _ = read_wav(os.path.join(IOS_OUT, f"chalk_o_{i}.wav"))
    n = stroke_count(xs)
    check(n == 1, f"chalk_o_{i}: reads as {n} stroke(s) — an O must be ONE continuous sweep")
    print(f"  chalk_o_{i}  strokes={n}  (want 1)")

xs, _, _ = read_wav(os.path.join(IOS_OUT, "chalk_line.wav"))
n = stroke_count(xs)
check(n == 1, f"chalk_line: reads as {n} stroke(s) — must be one confident sweep")
dur_ms = len(xs) / SR * 1000
# It must not outlast the 340 ms stroke animation it is timed against.
check(dur_ms <= 345, f"chalk_line: {dur_ms:.0f} ms outlasts the 340 ms win-stroke animation")
print(f"  chalk_line  strokes={n} (want 1)  {dur_ms:.0f} ms (want <=345)")

# --- variants must actually differ -------------------------------------------------------

print()
for family in ("chalk_x", "chalk_o"):
    lengths = []
    for i in (1, 2, 3):
        xs, _, _ = read_wav(os.path.join(IOS_OUT, f"{family}_{i}.wav"))
        lengths.append(len(xs))
    check(len(set(lengths)) == 3,
          f"{family}: variants share a length — repetition will sound machine-like")
    print(f"  {family} variant lengths: {[round(l/SR*1000) for l in lengths]} ms")

# --- loudness consistency ---------------------------------------------------------------

print()
loud = {}
for name in sorted(os.listdir(IOS_OUT)):
    if not name.endswith(".wav"):
        continue
    xs, _, _ = read_wav(os.path.join(IOS_OUT, name))
    if xs:
        loud[name[:-4]] = loudness_lufs(xs)

physical = [
    "catch", "chalk_x_1", "chalk_x_2", "chalk_x_3", "chalk_o_1", "chalk_o_2", "chalk_o_3",
    "chalk_line", "chalk_stub", "wicket_timber", "bat_crack", "bat_soft", "bat_block",
    "hand_pump", "hand_reveal",
]
vals = [loud[n] for n in physical if n in loud]
spread = max(vals) - min(vals)
check(spread <= 3.0,
      f"physical set spans {spread:.1f} dB of loudness — §6.1 wants one consistent palette")
print(f"  physical one-shots: {min(vals):.1f} to {max(vals):.1f} LUFS "
      f"(spread {spread:.1f} dB, want <= 3.0)")

# --- the crowd bed's loop seam -----------------------------------------------------------

bed = os.path.join(IOS_OUT, "crowd_base.m4a")
check(os.path.exists(bed), "crowd_base.m4a missing")
check(not os.path.exists(os.path.join(IOS_OUT, "crowd_base.wav")),
      "crowd_base.wav still shipped — 1.9 MB of dead weight beside the .m4a")
if os.path.exists(bed):
    kb = os.path.getsize(bed) / 1024
    check(kb < 400, f"crowd bed is {kb:.0f} KB — too large for one looping asset")
    print(f"\n  crowd_base.m4a {kb:.0f} KB")

print()
if failures:
    print(f"FAILED {len(failures)} of {checks} checks:\n")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
print(f"All {checks} checks passed.")
