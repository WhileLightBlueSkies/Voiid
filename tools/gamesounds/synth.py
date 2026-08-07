#!/usr/bin/env python3
"""
Voiid game sound generator — stdlib only, no dependencies.

Renders every sound in docs/GAMES_AUDIO.md to 16-bit mono WAV at 44.1 kHz,
then (if `afconvert` is available, i.e. on macOS) also emits an AAC .m4a
copy for anything longer than 500 ms, per the doc's format table (§6).

THIS IS NOT PART OF EITHER APP'S BUILD. Run it by hand when a sound needs to
change; commit the generated files. That keeps the game builds free of a
Python dependency and makes every change to the audio a reviewable binary
diff rather than a build-time side effect.

Usage:
    python3 tools/gamesounds/synth.py
    python3 tools/gamesounds/synth.py --game snake     # just one game's set
    python3 tools/gamesounds/synth.py --list           # show what would render

Output layout mirrors docs/GAMES_AUDIO.md §3:
    apps/ios/Voiid/Voiid/Resources/GameSounds/*.wav (+ .m4a for long sounds)
    apps/android/app/src/main/res/raw/*.wav          (Android res/raw: lowercase, no dots)
"""
from __future__ import annotations

import argparse
import array
import math
import os
import random
import shutil
import subprocess
import wave
from dataclasses import dataclass, field
from typing import Callable

SR = 44100
OVERSAMPLE = 4  # render at 4x and average down — cheap anti-aliasing, doc §7.3

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
IOS_OUT = os.path.join(REPO_ROOT, "apps/ios/Voiid/Voiid/Resources/GameSounds")
ANDROID_OUT = os.path.join(REPO_ROOT, "apps/android/app/src/main/res/raw")

# Sounds longer than this also get an AAC copy per the doc's format table.
AAC_THRESHOLD_S = 0.5


# --- §7.2 the primitive vocabulary -------------------------------------------------

def sine(t: float, f: float) -> float:
    return math.sin(2 * math.pi * f * t)


def saw(t: float, f: float) -> float:
    return 2 * ((t * f) % 1) - 1


def square(t: float, f: float, duty: float = 0.5) -> float:
    return 1.0 if (t * f) % 1 < duty else -1.0


def noise() -> float:
    return random.uniform(-1, 1)


def decay(p: float, k: float) -> float:
    """Percussive exponential decay. p is progress 0..1."""
    return math.exp(-p * k)


def ar(p: float, a: float = 0.05) -> float:
    """Attack-release envelope."""
    return p / a if p < a else (1 - p) / max(1 - a, 1e-9)


def sweep(p: float, f0: float, f1: float, curve: float = 1.0) -> float:
    """Pitch glide. curve > 1 = fast-then-slow; < 1 = slow-then-fast."""
    return f0 + (f1 - f0) * (p ** curve)


# --- renderer ------------------------------------------------------------------------

@dataclass
class Sound:
    name: str
    game: str  # "snake" | "tictactoe" | "rps" | "cricket" | "ui"
    duration: float
    fn: Callable[[float, float], float]
    gain: float = 0.7  # §11 per-tier trim is applied by the caller; this is the recipe's own headroom


def render_samples(dur: float, fn: Callable[[float, float], float], gain: float) -> array.array:
    """Render at OVERSAMPLE x SR, box-filter down to SR. Removes the aliasing that a
    naive saw/square sweep produces on an upward glide (doc §7.3)."""
    hi_sr = SR * OVERSAMPLE
    n_hi = int(hi_sr * dur)
    hi = array.array("d", [0.0]) * n_hi
    for i in range(n_hi):
        t = i / hi_sr
        p = i / n_hi if n_hi else 0.0
        s = fn(t, p)
        hi[i] = max(-1.0, min(1.0, s))

    n_lo = int(SR * dur)
    out = array.array("h")
    for i in range(n_lo):
        lo = i * OVERSAMPLE
        window = hi[lo: lo + OVERSAMPLE]
        avg = sum(window) / len(window) if window else 0.0
        avg = max(-1.0, min(1.0, avg * gain))
        out.append(int(avg * 32767))
    return out


def peak_normalize(samples: array.array, target_dbfs: float = -3.0) -> array.array:
    """§11: peak-normalize every file to -3 dBFS before the per-sound mix trim is
    applied at playback. Never ship a 0 dBFS file — pitch-shifted playback can clip."""
    peak = max((abs(s) for s in samples), default=0)
    if peak == 0:
        return samples
    target_peak = 32767 * (10 ** (target_dbfs / 20))
    scale = target_peak / peak
    return array.array("h", (int(max(-32768, min(32767, s * scale))) for s in samples))


def write_wav(path: str, samples: array.array) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(samples.tobytes())


def maybe_encode_aac(wav_path: str, m4a_path: str) -> bool:
    """afconvert is macOS-only. Skip quietly elsewhere — the WAV is always produced
    and is sufficient for both app targets to bundle directly if this step is
    unavailable (WAV bundled uncompressed costs ~2x the size, never a decode issue)."""
    if shutil.which("afconvert") is None:
        return False
    subprocess.run(
        ["afconvert", "-f", "m4af", "-d", "aac", "-b", "96000", wav_path, m4a_path],
        check=True, capture_output=True,
    )
    return True


# --- §8 Snake -------------------------------------------------------------------------

def _eat(base_f0: float, base_f1: float):
    def fn(t: float, p: float) -> float:
        f = sweep(p, base_f0, base_f1)
        env = decay(p, 9)
        return (sine(t, f) + 0.3 * sine(t, f * 2)) * env
    return fn


# 8.1 four pitch variants, minor-third spaced, so mass buckets are distinguishable
# without needing continuous runtime pitch (doc §7.4 "bake variants").
_EAT_VARIANTS = [0.84, 1.0, 1.19, 1.41]


def eat_big(t: float, p: float) -> float:
    """8.2 eatBig — fuller, lower, richer than eat: an extra sub harmonic and a
    slower decay so corpse food reads as a bigger reward."""
    f = sweep(p, 420, 760)
    env = decay(p, 6)
    return (sine(t, f) + 0.35 * sine(t, f * 2) + 0.25 * sine(t, f * 0.5)) * env


def boost_start(t: float, p: float) -> float:
    """8.3 rising whoosh: filtered-feeling noise via a rising sine carrier over a
    noise bed, cheap without a real filter."""
    f = sweep(p, 200, 900, curve=0.6)
    bed = noise() * 0.35 * ar(p, a=0.6)
    return sine(t, f) * ar(p, a=0.3) * 0.7 + bed


def boost_loop(t: float, p: float) -> float:
    """8.4 boostLoop bed — a single loop iteration; the caller loops the buffer.
    Low, filtered-noise character, quiet by design (§11 'bed' tier)."""
    lfo = 0.6 + 0.4 * math.sin(2 * math.pi * 6 * t)
    return noise() * 0.5 * lfo


def boost_end(t: float, p: float) -> float:
    """8.5 falling tail — the mirror of boost_start."""
    f = sweep(p, 700, 150, curve=1.4)
    return sine(t, f) * decay(p, 4) * 0.6


def kill(t: float, p: float) -> float:
    """8.6 impact + descending sweep + a felt (not heard, on a phone speaker) sub."""
    impact = noise() * decay(p, 40) * 0.8
    tone = sine(t, sweep(p, 420, 130, curve=0.5)) * decay(p, 5)
    sub = sine(t, 70) * decay(p, 8) * 0.5
    return impact + tone + sub


def death(t: float, p: float) -> float:
    """8.7 the dramatic one — crack, pitch collapse, low rumble fading across the
    death panel's own 700ms. Envelope mirrors the 0.3x/500ms slow-mo + 400ms
    desaturation in docs/GAMES_ANIMATION.md so audio and visual land together."""
    crack = noise() * decay(p, 55)
    fall = saw(t, sweep(p, 300, 45, curve=0.7)) * decay(p, 3) * 0.6
    rumble = sine(t, 55) * (1 - p) * 0.7
    return crack + fall + rumble


def spawn(t: float, p: float) -> float:
    """8.8 rising shimmer that resolves up — the opposite gesture of death."""
    f = sweep(p, 300, 640, curve=0.8)
    shimmer = 0.25 * sine(t, f * 2.01)  # slightly detuned for a shimmer beat
    return (sine(t, f) + shimmer) * ar(p, a=0.15)


def border_warn(t: float, p: float) -> float:
    """8.9 low pulse loop, ~2 Hz — dread, not alarm. Caller scales gain by proximity
    to the lethal wall; this is one loop iteration."""
    pulse = 0.5 + 0.5 * math.sin(2 * math.pi * 2 * t)
    return sine(t, 90) * pulse * 0.6


def rank_up(t: float, p: float) -> float:
    """8.10 two-note rise."""
    f = 440 if p < 0.5 else 587
    local_p = (p * 2) % 1
    return sine(t, f) * decay(local_p, 14)


def match_end(t: float, p: float) -> float:
    """8.11 resolving chord — three sines landing on a major triad, staggered
    entrance so it reads as arriving rather than switching on."""
    root, third, fifth = 220, 277, 330
    a1 = ar(min(p * 1.3, 1.0), a=0.1)
    a2 = ar(min(max(p - 0.08, 0) * 1.3, 1.0), a=0.1) if p > 0.08 else 0
    a3 = ar(min(max(p - 0.16, 0) * 1.3, 1.0), a=0.1) if p > 0.16 else 0
    return (sine(t, root) * a1 + sine(t, third) * a2 + sine(t, fifth) * a3) * 0.5


SNAKE_SOUNDS: list[Sound] = [
    *[Sound(f"eat_{i+1}", "snake", 0.09, _eat(660 * m, 1200 * m), gain=0.6)
      for i, m in enumerate(_EAT_VARIANTS)],
    Sound("eat_big", "snake", 0.14, eat_big, gain=0.65),
    Sound("boost_start", "snake", 0.18, boost_start, gain=0.6),
    Sound("boost_loop", "snake", 0.5, boost_loop, gain=0.35),   # §11 bed tier: quiet
    Sound("boost_end", "snake", 0.12, boost_end, gain=0.55),
    Sound("kill", "snake", 0.4, kill, gain=0.75),
    Sound("death", "snake", 0.7, death, gain=0.85),
    Sound("spawn", "snake", 0.35, spawn, gain=0.6),
    Sound("border_warn", "snake", 0.5, border_warn, gain=0.3),  # §11 bed tier
    Sound("rank_up", "snake", 0.25, rank_up, gain=0.5),
    Sound("match_end", "snake", 1.2, match_end, gain=0.85),
]


# --- §9 board games ---------------------------------------------------------------

def _mark_place(base: float):
    def fn(t: float, p: float) -> float:
        body = sine(t, base) * decay(p, 22)
        click = noise() * decay(p, 90) * 0.35
        return body + click
    return fn


def mark_invalid(t: float, p: float) -> float:
    """dull muted thud, deliberately unsatisfying."""
    return sine(t, 140) * decay(p, 30) * 0.5 + noise() * decay(p, 120) * 0.15


def win_line(t: float, p: float) -> float:
    """ascending three-note arpeggio, timed to the line-sweep animation (450ms
    per docs/GAMES_ANIMATION.md §6.1)."""
    notes = [440, 554, 659]
    idx = min(int(p * 3), 2)
    local_p = (p * 3) % 1
    return sine(t, notes[idx]) * decay(local_p, 8) * 0.6


def draw_sound(t: float, p: float) -> float:
    """two flat, unresolved notes."""
    f = 330 if p < 0.5 else 294
    return sine(t, f) * 0.4


def countdown_tick(f: float):
    def fn(t: float, p: float) -> float:
        return sine(t, f) * decay(p, 30)
    return fn


def reveal(t: float, p: float) -> float:
    """sharp swish — both hands land together."""
    return noise() * decay(p, 25) * 0.5 + sine(t, sweep(p, 800, 300)) * decay(p, 10) * 0.4


def round_win(t: float, p: float) -> float:
    return (sine(t, sweep(p, 440, 660)) + 0.3 * sine(t, sweep(p, 440, 660) * 1.5)) * decay(p, 5)


def round_lose(t: float, p: float) -> float:
    return (sine(t, sweep(p, 440, 260)) + 0.3 * sine(t, sweep(p, 440, 260) * 0.5)) * decay(p, 5) * 0.8


def round_tie(t: float, p: float) -> float:
    return sine(t, 349) * decay(p, 14) * 0.5


def pick(t: float, p: float) -> float:
    return sine(t, 600) * decay(p, 45) * 0.5


def _runs(n: int):
    """9. runs — one recipe, six audible outcomes; pitch scales with runs scored."""
    def fn(t: float, p: float) -> float:
        f = 300 + n * 85
        return (sine(t, f) + 0.25 * sine(t, f * 3)) * decay(p, 12)
    return fn


def four(t: float, p: float) -> float:
    crack = noise() * decay(p, 35) * 0.6
    swell = sine(t, sweep(p, 500, 700)) * ar(p, a=0.2) * 0.5
    return crack + swell


def six(t: float, p: float) -> float:
    crack = noise() * decay(p, 25) * 0.65
    swell = (sine(t, sweep(p, 400, 900)) + 0.3 * sine(t, sweep(p, 400, 900) * 1.5)) * ar(p, a=0.15) * 0.55
    return crack + swell


def wicket(t: float, p: float) -> float:
    """descending break, clearly negative."""
    crack = noise() * decay(p, 30) * 0.6
    fall = saw(t, sweep(p, 350, 90, curve=0.6)) * decay(p, 4) * 0.5
    return crack + fall


def innings(t: float, p: float) -> float:
    """neutral transition chime."""
    return (sine(t, 392) * ar(p, a=0.15) + sine(t, 494) * ar(min(max(p - 0.1, 0) * 1.2, 1.0), a=0.15) * 0.6) * 0.5


TTT_SOUNDS: list[Sound] = [
    Sound("mark_x", "tictactoe", 0.08, _mark_place(520), gain=0.55),
    Sound("mark_o", "tictactoe", 0.08, _mark_place(392), gain=0.55),
    Sound("mark_invalid", "tictactoe", 0.12, mark_invalid, gain=0.45),
    Sound("win_line", "tictactoe", 0.5, win_line, gain=0.7),
    Sound("draw", "tictactoe", 0.4, draw_sound, gain=0.5),
]

RPS_SOUNDS: list[Sound] = [
    Sound("countdown_1", "rps", 0.12, countdown_tick(440), gain=0.5),
    Sound("countdown_2", "rps", 0.12, countdown_tick(554), gain=0.5),
    Sound("countdown_3", "rps", 0.12, countdown_tick(659), gain=0.55),
    Sound("reveal", "rps", 0.2, reveal, gain=0.65),
    Sound("round_win", "rps", 0.35, round_win, gain=0.7),
    Sound("round_lose", "rps", 0.35, round_lose, gain=0.65),
    Sound("round_tie", "rps", 0.2, round_tie, gain=0.5),
]

CRICKET_SOUNDS: list[Sound] = [
    Sound("pick", "cricket", 0.07, pick, gain=0.45),
    *[Sound(f"runs_{n}", "cricket", 0.18, _runs(n), gain=0.55) for n in range(1, 7)],
    Sound("four", "cricket", 0.4, four, gain=0.7),
    Sound("six", "cricket", 0.6, six, gain=0.8),
    Sound("wicket", "cricket", 0.5, wicket, gain=0.75),
    Sound("innings", "cricket", 0.7, innings, gain=0.55),
]


# --- §10 shared UI ------------------------------------------------------------------

def tap(t: float, p: float) -> float:
    return sine(t, 800) * decay(p, 60) * 0.4


def sheet_open(t: float, p: float) -> float:
    return sine(t, sweep(p, 300, 500)) * ar(p, a=0.3) * 0.4


def sheet_close(t: float, p: float) -> float:
    return sine(t, sweep(p, 500, 250)) * decay(p, 6) * 0.4


def match_found(t: float, p: float) -> float:
    f = 523 if p < 0.5 else 659
    return sine(t, f) * decay((p * 2) % 1, 10) * 0.55


def invite_arrive(t: float, p: float) -> float:
    """Deliberately distinct from the message notification tone (doc §10) —
    brighter and melodic rather than a flat ping, so the two are never confused."""
    notes_p = [0.0, 0.35]
    f = [660, 880]
    idx = 0 if p < 0.35 else 1
    local = (p - notes_p[idx]) / (0.35 if idx == 0 else 0.65)
    return sine(t, f[idx]) * decay(min(max(local, 0), 1), 8) * 0.5


def error_sound(t: float, p: float) -> float:
    """low double-buzz."""
    beat = 1.0 if (p * 2) % 1 < 0.5 else 0.0
    return square(t, 180) * beat * decay((p * 2) % 1, 10) * 0.35


UI_SOUNDS: list[Sound] = [
    Sound("tap", "ui", 0.05, tap, gain=0.4),
    Sound("sheet_open", "ui", 0.18, sheet_open, gain=0.4),
    Sound("sheet_close", "ui", 0.14, sheet_close, gain=0.4),
    Sound("match_found", "ui", 0.5, match_found, gain=0.55),
    Sound("invite_arrive", "ui", 0.4, invite_arrive, gain=0.5),
    Sound("error", "ui", 0.25, error_sound, gain=0.35),
]

ALL_SOUNDS: list[Sound] = SNAKE_SOUNDS + TTT_SOUNDS + RPS_SOUNDS + CRICKET_SOUNDS + UI_SOUNDS


# --- driver ---------------------------------------------------------------------------

def android_res_name(name: str) -> str:
    """Android raw resource names must be lowercase [a-z0-9_] — already satisfied by
    the naming convention above, but normalize defensively."""
    return "".join(c if (c.isalnum() or c == "_") else "_" for c in name.lower())


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--game", choices=["snake", "tictactoe", "rps", "cricket", "ui"],
                     help="render only this game's set")
    ap.add_argument("--list", action="store_true", help="print what would render and exit")
    ap.add_argument("--seed", type=int, default=7, help="RNG seed, for reproducible noise-based sounds")
    args = ap.parse_args()

    sounds = [s for s in ALL_SOUNDS if args.game is None or s.game == args.game]

    if args.list:
        for s in sounds:
            print(f"{s.game:10s} {s.name:16s} {s.duration*1000:6.0f} ms")
        print(f"\n{len(sounds)} sounds")
        return

    random.seed(args.seed)

    aac_available = shutil.which("afconvert") is not None
    if not aac_available:
        print("afconvert not found (non-macOS host) — shipping WAV only; "
              "see docs/GAMES_AUDIO.md §6, WAV is fully sufficient to bundle.")

    for s in sounds:
        samples = render_samples(s.duration, s.fn, s.gain)
        samples = peak_normalize(samples)

        wav_ios = os.path.join(IOS_OUT, f"{s.name}.wav")
        write_wav(wav_ios, samples)

        android_name = android_res_name(s.name)
        wav_android = os.path.join(ANDROID_OUT, f"{android_name}.wav")
        write_wav(wav_android, samples)

        tag = ""
        if s.duration > AAC_THRESHOLD_S and aac_available:
            m4a_ios = os.path.join(IOS_OUT, f"{s.name}.m4a")
            maybe_encode_aac(wav_ios, m4a_ios)
            tag = " (+m4a)"

        print(f"  {s.game:10s} {s.name:16s} {s.duration*1000:6.0f} ms{tag}")

    print(f"\n{len(sounds)} sounds rendered to:")
    print(f"  {os.path.relpath(IOS_OUT, REPO_ROOT)}/")
    print(f"  {os.path.relpath(ANDROID_OUT, REPO_ROOT)}/")


if __name__ == "__main__":
    main()
