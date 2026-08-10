#!/usr/bin/env python3
"""
Voiid game sound generator — the PHYSICAL half (docs/games/SOUND_DESIGN.md).

`synth.py` renders the abstract palette: UI ticks, and all of Snake, which is a neon arcade
game with no real-world referent and is deliberately left retro. THIS file renders the
sounds that model real objects — a leather slap, chalk on slate, a ball into stumps, willow
on leather, and a stadium — because those are noise processes and resonating bodies, and an
oscillator vocabulary cannot make one.

Everything here is SYNTHESISED FROM PHYSICAL MODELS, not sampled. No third-party audio is
downloaded, sourced or shipped, which is the whole reason `LICENSES.md` next to this file is
short. See that file before adding anything from outside.

THE ONE HARD RULE: every asset is MONO. GameAudio.swift wires its entire graph mono, and a
stereo buffer scheduled onto a mono bus is an ObjC NSException that `try?` cannot catch — the
process dies. It was the Snake-screen crash. Everything here is mono by construction.

Usage:
    python3 tools/gamesounds/physical.py
    python3 tools/gamesounds/physical.py --list
    python3 tools/gamesounds/physical.py --only catch,chalk_x_1
    python3 tools/gamesounds/physical.py --game cricket

Output mirrors synth.py:
    apps/ios/Voiid/Voiid/Resources/GameSounds/*.wav (+ .m4a over 500 ms)
    apps/android/app/src/main/res/raw/*.wav          (or .m4a alone, for the crowd bed)
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

from dsp import (
    SR, at, bandpass, cap_length, env_ar, env_exp, gain, grain_train, highpass,
    loop_crossfade, loudness_lufs, lowpass, mix, modal, normalize_lufs, peaking,
    poisson_impulses, room, seconds, silence, trim_silence, white,
)

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
IOS_OUT = os.path.join(REPO_ROOT, "apps/ios/Voiid/Voiid/Resources/GameSounds")
ANDROID_OUT = os.path.join(REPO_ROOT, "apps/android/app/src/main/res/raw")

# --- §6 mastering targets --------------------------------------------------------------
#
# Applied to every sound below, uniformly, at the END of rendering. That uniformity is the
# entire point of a mastering pass: 25 sounds built from six different models will not sit
# together on their own, and consistency can only be judged against the full palette.

LUFS_ONESHOT = -16.0        # §6.1
LUFS_BED = -26.0            # the crowd bed lives UNDERNEATH everything
HP_CUTOFF = 80.0            # §6.2 — phone speakers reproduce nothing below this
ONESHOT_MAX_S = 0.8         # §6.5 — long tails overlap the next event and turn a game to mud
AAC_THRESHOLD_S = 0.5


@dataclass
class Physical:
    name: str
    game: str
    render: Callable[[random.Random], list[float]]
    lufs: float = LUFS_ONESHOT
    #: §6.2 exempts deliberate impacts — a wicket loses its weight high-passed at 80 Hz.
    highpass_80: bool = True
    max_s: float = ONESHOT_MAX_S
    #: Ship the .m4a INSTEAD of the .wav, on BOTH platforms. Only for the bed: a 22 s mono
    #: WAV is 1.9 MB against a 4 MB per-platform budget, and at 64 kbps it is 180 KB. On
    #: Android it is also a correctness requirement — two files sharing a base name in
    #: res/raw is a duplicate-resource build failure, since getIdentifier() resolves on the
    #: name without its extension.
    aac_only: bool = False
    note: str = ""


# =======================================================================================
# §3 — the shared catch. One file, played unmodified, in all four games.
# =======================================================================================

def render_catch(rng: random.Random) -> list[float]:
    """Leather on palm: a hand closing hard around a ball.

    Three layers, because that is what the real event is. The SLAP is broadband and almost
    instantaneous — skin against leather, most of its energy 900 Hz-3 kHz. Under it sits the
    BODY, the dull thud of a hand's own mass, an octave and a half down. Over the top, a
    scrap of room so it is a sound that happened somewhere rather than a sample.

    It must survive being heard thirty times in one Snake match without becoming irritating,
    which is what rules out anything bright or ringing — note the 4.5 kHz lowpass and the
    complete absence of a resonant tail.
    """
    n = seconds(0.18)

    slap = bandpass(white(n, rng), 1500, q=0.8)
    slap = lowpass(slap, 4500)
    slap = [v * e for v, e in zip(slap, env_exp(n, 42, attack_s=0.0012))]

    body = bandpass(white(n, rng), 240, q=1.2)
    body = [v * e * 0.85 for v, e in zip(body, env_exp(n, 26, attack_s=0.003))]

    dry = mix(gain(slap, 1.0), gain(body, 0.55))
    return room(dry, mix=0.16, size=0.55, damp=0.5)


# =======================================================================================
# §4.3 — Tic Tac Toe chalk. X is two strokes, O is one sweep. That is the whole point.
# =======================================================================================

def _chalk(
    rng: random.Random,
    dur: float,
    body_hz: float,
    strokes: list[tuple[float, float]],
    rate_lo: float,
    rate_hi: float,
    bright: float = 1.0,
    press: float = 1.0,
    bite: float = 1.0,
    taper: float = 0.55,
) -> list[float]:
    """One chalk gesture on slate.

    Chalk does not scrape, it STICK-SLIPS: it grabs the surface, tension builds, it releases,
    hundreds of times a second. The sound is that impact train ringing the slate, so the
    model is a grain train (the impacts) gating resonant noise (the slate). Getting this
    right is why chalk reads as chalk and not as hiss — hiss is what you get if you model it
    as filtered noise with a smooth envelope, which is the obvious and wrong approach.

    `strokes` is a list of (start, end) as fractions of the gesture. ONE entry is a
    continuous sweep — an O. TWO entries with a gap between them is a pair of strikes — an X.

    `bite` scales the tick where the chalk first catches, and `taper` how fast pressure comes
    off across the stroke. Both matter more than they look: a loud bite over a tapering
    scrape makes the envelope dip below the attack and the gesture reads as TWO events, which
    is right for an X and wrong for anything meant to be one continuous line.
    """
    n = seconds(dur)

    # The slate: broadband noise with a strong resonance where the surface rings, plus a
    # gentle top-end tilt for the chalk dust.
    slate = white(n, rng)
    slate = bandpass(slate, body_hz, q=0.55)
    slate = peaking(slate, body_hz * 2.1, 1.4, 5.0 * bright)
    slate = highpass(slate, 320)
    slate = lowpass(slate, 7200 * bright)

    def rate_at(p: float) -> float:
        # Faster mid-stroke than at either end: the hand accelerates away from the start and
        # decelerates into the finish, and the grain rate is what carries that.
        return rate_lo + (rate_hi - rate_lo) * math.sin(math.pi * min(max(p, 0.0), 1.0))

    train = grain_train(n, rate_at, rng, grain_s=0.0018, jitter=0.6)

    # Per-stroke amplitude: a percussive attack where the chalk first bites, then a scrape
    # that tapers as pressure comes off.
    shape = [0.0] * n
    for s0, s1 in strokes:
        a, b = int(n * s0), int(n * s1)
        span = max(b - a, 1)
        for i in range(a, min(b, n)):
            p = (i - a) / span
            attack = min(p / 0.06, 1.0) if p < 0.06 else 1.0
            shape[i] += attack * (1 - p) ** taper

    out = [slate[i] * train[i] * shape[i] * press for i in range(n)]

    # The bite: each stroke opens with a hard tick, the chalk catching before it moves.
    for s0, _ in strokes:
        tick_n = seconds(0.012)
        tick = bandpass(white(tick_n, rng), body_hz * 2.6, q=1.1)
        tick = [v * e for v, e in zip(tick, env_exp(tick_n, 60, attack_s=0.0006))]
        out = mix(out, at(gain(tick, 0.5 * press * bite), s0 * dur, n))

    # A dry, small room — a classroom, not a hall. Chalk sounds must share ONE space with
    # each other; mixing a reverberant chalk with a dry one is the single most common tell
    # of audio assembled from different sources.
    return room(out, mix=0.12, size=0.4, damp=0.6)


def render_chalk_x(variant: int) -> Callable[[random.Random], list[float]]:
    """An X is TWO STRIKES. You can hear it is two lines: sharp, angular, a tiny gap between.

    The gap is the information. A player learns to hear whose turn resolved without looking,
    which is a real accessibility win as much as a texture one.
    """
    # Small per-variant differences in length, gap and brightness. Chalk is never identical
    # twice, and Tic Tac Toe fires this up to nine times in thirty seconds — the most
    # repetition-exposed sound in the game. Identical variants go machine-like by move four.
    dur = [0.255, 0.268, 0.245][variant]
    gap = [0.10, 0.13, 0.08][variant]
    first_end = 0.42
    second_start = first_end + gap

    def fn(rng: random.Random) -> list[float]:
        return _chalk(
            rng, dur, body_hz=[1500, 1620, 1420][variant],
            strokes=[(0.0, first_end), (second_start, 1.0)],
            rate_lo=520, rate_hi=1350,
            bright=[1.0, 1.08, 0.94][variant],
            press=[1.0, 0.94, 1.06][variant],
        )
    return fn


def render_chalk_o(variant: int) -> Callable[[random.Random], list[float]]:
    """An O is ONE CONTINUOUS SWEEP. Smoother, sustained, no internal break.

    Rounder and less attacky than the X by construction: a single stroke entry, a lower
    resonance, and a grain rate that never restarts. Drawing a circle is one motion, and the
    sound has to be one motion too.
    """
    dur = [0.300, 0.288, 0.312][variant]

    def fn(rng: random.Random) -> list[float]:
        return _chalk(
            rng, dur, body_hz=[1180, 1250, 1120][variant],
            strokes=[(0.0, 1.0)],
            rate_lo=620, rate_hi=1150,
            bright=[0.92, 0.97, 0.88][variant],
            press=[0.95, 0.99, 0.92][variant],
        )
    return fn


def render_chalk_line(rng: random.Random) -> list[float]:
    """The winning line: one long, confident, continuous scrape. Drawn HARDER.

    340 ms, matched exactly to the stroke animation in TICTACTOE_WIN_LINE.md §2.2 — it
    starts on the frame the stroke begins and must not outlast it. A scrape still going
    after the line has stopped moving is the kind of mismatch that reads as broken without
    the player being able to name why.

    Louder and lower than the mark sounds, because this is the decisive gesture.
    """
    return _chalk(
        rng, 0.335, body_hz=920,
        strokes=[(0.0, 1.0)],
        rate_lo=780, rate_hi=1500,
        bright=0.85, press=1.35,
        # A soft bite and a near-flat taper. Drawn HARDER means sustained pressure through
        # the stroke, not a harder tap at the start — and a loud bite over a fading scrape
        # measurably reads as two events (see verify.py's stroke_count), which is the
        # opposite of the one confident sweep this is supposed to be.
        bite=0.3, taper=0.18,
    )


def render_chalk_stub(rng: random.Random) -> list[float]:
    """An illegal move: a short dull chalk tap that goes nowhere.

    Physically "that didn't take" — the chalk touched down and never travelled, so there is
    a bite and no scrape at all. Deliberately unsatisfying.
    """
    n = seconds(0.10)
    tap = bandpass(white(n, rng), 780, q=0.9)
    tap = lowpass(tap, 2600)
    tap = [v * e for v, e in zip(tap, env_exp(n, 16, attack_s=0.0015))]
    return room(gain(tap, 0.8), mix=0.10, size=0.4, damp=0.6)


def render_chalk_erase(rng: random.Random) -> list[float]:
    """A duster wiping the slate — the sound of a draw.

    Felt on stone: much broader and softer-edged than chalk, no discrete bite, and three
    overlapping passes rather than one, because nobody wipes a board once. This is what
    gives a draw its own identity instead of borrowing the loss treatment.
    """
    n = seconds(0.62)
    bed = white(n, rng)
    bed = bandpass(bed, 1350, q=0.35)
    bed = highpass(bed, 400)
    bed = lowpass(bed, 5200)

    shape = [0.0] * n
    for start, length, amp in ((0.02, 0.26, 1.0), (0.22, 0.24, 0.85), (0.42, 0.20, 0.6)):
        a = int(n * start / 0.62)
        b = min(a + int(SR * length), n)
        span = max(b - a, 1)
        for i in range(a, b):
            p = (i - a) / span
            shape[i] += amp * math.sin(math.pi * p) ** 1.3

    out = [bed[i] * min(shape[i], 1.2) for i in range(n)]
    return room(out, mix=0.14, size=0.45, damp=0.55)


# =======================================================================================
# §4.1 — Hand Cricket. Impacts, then the stadium.
# =======================================================================================

def render_wicket_timber(rng: random.Random) -> list[float]:
    """Ball into stumps: a hard woody CRACK plus the light rattle of bails falling.

    This is the sound the brief specifically asked for, and it is two distinct bodies. The
    STUMP is a heavy ash rod — low modes, long decay. The BAILS are small, light and loose,
    so they are high modes with a fast decay, struck several times at irregular intervals as
    they tumble. Modelling them separately is what produces "wicket" instead of "thud".

    Dry and close-mic'd on purpose: the room is supplied by the crowd bed sitting under it,
    and a reverberant stump plus a reverberant crowd is mud.

    NOT high-passed at 80 Hz — §6.2 exempts deliberate impacts, and the weight of this one
    lives exactly there.
    """
    n = seconds(0.55)

    strike = bandpass(white(seconds(0.02), rng), 2400, q=0.7)
    strike = [v * e for v, e in zip(strike, env_exp(len(strike), 70, attack_s=0.0004))]

    stump = modal(seconds(0.34), [
        (168, 0.085, 1.00),     # the rod's fundamental bend
        (296, 0.070, 0.62),
        (533, 0.045, 0.41),
        (881, 0.028, 0.24),
        (1420, 0.016, 0.13),
    ], rng)
    stump = [v * e for v, e in zip(stump, env_exp(len(stump), 3.0, attack_s=0.0009))]

    out = mix(at(gain(strike, 0.9), 0.0, n), at(gain(stump, 0.8), 0.0, n))

    # Bails: three to five taps, irregularly spaced, each lighter than the last.
    count = rng.randint(3, 5)
    t = 0.055
    for k in range(count):
        bail_n = seconds(0.11)
        bail = modal(bail_n, [
            (1380 * rng.uniform(0.92, 1.09), 0.020, 1.0),
            (2170 * rng.uniform(0.92, 1.09), 0.013, 0.55),
            (3060 * rng.uniform(0.92, 1.09), 0.008, 0.3),
        ], rng)
        bail = [v * e for v, e in zip(bail, env_exp(bail_n, 9, attack_s=0.0006))]
        out = mix(out, at(gain(bail, 0.30 * (0.75 ** k)), t, n))
        t += rng.uniform(0.045, 0.105)

    return out


def _bat(rng: random.Random, dur: float, modes, brightness: float, punch: float,
         lp: float) -> list[float]:
    """Willow meeting leather. The bat is the resonator; the ball is the exciter."""
    n = seconds(dur)
    contact = bandpass(white(seconds(0.014), rng), 1900 * brightness, q=0.6)
    contact = [v * e for v, e in zip(contact, env_exp(len(contact), 65, attack_s=0.0005))]

    blade = modal(seconds(dur * 0.8), modes, rng)
    blade = [v * e for v, e in zip(blade, env_exp(len(blade), 4.5, attack_s=0.001))]

    out = mix(at(gain(contact, punch), 0.0, n), at(gain(blade, 0.75), 0.0, n))
    return lowpass(out, lp)


def render_bat_crack(rng: random.Random) -> list[float]:
    """A four or a six — the middle of the bat, hit properly. Real willow crack."""
    return _bat(rng, 0.30, [
        (415, 0.055, 1.0), (762, 0.038, 0.66), (1490, 0.022, 0.42), (2380, 0.012, 0.22),
    ], brightness=1.15, punch=1.0, lp=9000)


def render_bat_soft(rng: random.Random) -> list[float]:
    """One to three runs: bat on ball, gently. A push, not a shot.

    This replaces the tonal `runs_1..3`, which encoded the run count in PITCH. That
    information is lost and it is an acceptable trade: the on-screen number carries it, and
    six distinct musical pitches was the most video-game thing left in the palette.
    """
    return _bat(rng, 0.22, [
        (388, 0.038, 1.0), (690, 0.024, 0.5), (1310, 0.013, 0.25),
    ], brightness=0.85, punch=0.55, lp=5200)


def render_bat_block(rng: random.Random) -> list[float]:
    """A dot ball: dull, muted, dead. Deliberately anticlimactic — a dot ball SHOULD deflate.

    Physically a block is the ball hitting a bat held soft, so almost nothing rings: heavy
    low-pass, no high modes, and a decay short enough that it is over before it registers.
    """
    n = seconds(0.17)
    thud = bandpass(white(n, rng), 260, q=1.0)
    thud = lowpass(thud, 900)
    thud = [v * e for v, e in zip(thud, env_exp(n, 11, attack_s=0.002))]
    dead = modal(seconds(0.12), [(196, 0.030, 1.0), (330, 0.018, 0.35)], rng)
    dead = [v * e for v, e in zip(dead, env_exp(len(dead), 4, attack_s=0.0015))]
    return mix(gain(thud, 0.9), at(gain(dead, 0.5), 0.0, n))


# --- the crowd -------------------------------------------------------------------------

def _babble(n: int, rng: random.Random, tilt_hz: float, bright: float,
            voices: int = 5) -> list[float]:
    """A distant crowd, as a noise process.

    A stadium heard from the middle distance has NO identifiable individual voices — that is
    a hard requirement (§5.3), because a distinct shout becomes a metronome the moment the
    bed loops. So the model is deliberately not "voices": it is several independently
    band-limited noise layers, each with its own slow random amplitude drift, summed. That
    produces the seething, formant-weighted texture of thousands of people and, by
    construction, nothing anyone could pick out or identify as a language.
    """
    out = [0.0] * n
    for v in range(voices):
        centre = tilt_hz * (0.62 + 0.38 * v / max(voices - 1, 1)) * rng.uniform(0.9, 1.1)
        layer = bandpass(white(n, rng), centre, q=0.42)

        # Slow drift, at frequencies chosen to be EXACT integer cycles across the buffer, so
        # the modulation itself is periodic over the loop and cannot betray the seam.
        cycles = [rng.randint(2, 7), rng.randint(9, 19)]
        depth = [0.28, 0.16]
        for i in range(n):
            p = i / n
            m = 1.0
            for c, d in zip(cycles, depth):
                m *= 1.0 + d * math.sin(2 * math.pi * c * p + v)
            out[i] += layer[i] * m
    out = gain(out, 1.0 / voices)
    out = highpass(out, 110)
    out = peaking(out, 640, 0.8, 4.0)
    # Distance and air absorption take the top off. A crowd with 8 kHz in it is a crowd
    # standing next to the microphone, and this one has to sit UNDER the game.
    return lowpass(out, 3400 * bright)


def _claps(n: int, rng: random.Random, density_at, amp: float) -> list[float]:
    """Sparse, Poisson-distributed hand claps. Evenly spaced claps are a drum machine."""
    out = [0.0] * n
    for t in poisson_impulses(n, density_at, rng):
        clap_n = seconds(0.05)
        c = bandpass(white(clap_n, rng), rng.uniform(900, 2200), q=0.7)
        c = lowpass(c, 4200)
        c = [v * e for v, e in zip(c, env_exp(clap_n, 55, attack_s=0.0006))]
        g = amp * rng.uniform(0.35, 1.0)
        for i, v in enumerate(c):
            if t + i < n:
                out[t + i] += v * g
    return out


CROWD_BED_S = 22.0


def render_crowd_base(rng: random.Random) -> list[float]:
    """The bed: continuous stadium ambience under the entire match.

    The single biggest upgrade in the app, and it is one file plus a gain curve. Twenty-two
    seconds so the period is long enough not to be recognised, wrap-crossfaded so there is
    no seam to recognise in the first place, and mixed with scattered distant applause so it
    breathes rather than sitting still.

    Its intensity is NOT baked in. The client ramps this same file's gain from 0.18 to 0.35
    as the required run rate climbs (SOUND_DESIGN.md §4.1) — one asset, three moods.
    """
    n = seconds(CROWD_BED_S)
    bed = _babble(n, rng, tilt_hz=720, bright=1.0, voices=6)
    scattered = _claps(n, rng, lambda p: 7.0, amp=0.10)
    scattered = lowpass(scattered, 2600)
    out = mix(gain(bed, 1.0), gain(scattered, 0.5))
    return loop_crossfade(out, fade_s=1.2)


def render_crowd_cheer(rng: random.Random) -> list[float]:
    """A four, or a wicket for the fielding side. A quick lift, then settling back."""
    n = seconds(1.7)
    body = _babble(n, rng, tilt_hz=980, bright=1.2, voices=5)
    env = env_ar(n, attack_s=0.13, release_s=1.05)
    body = [v * e for v, e in zip(body, env)]
    claps = _claps(n, rng, lambda p: 34 * math.exp(-2.1 * p), amp=0.45)
    return mix(gain(body, 1.0), gain(claps, 0.85))


def render_crowd_roar(rng: random.Random) -> list[float]:
    """A six, or a wicket falling. The biggest reaction in the game.

    Faster attack and much more low-mid weight than the cheer — a roar is felt in the chest,
    and on a phone speaker the only way to imply that is the 200-500 Hz band, since anything
    genuinely low simply is not reproduced.
    """
    n = seconds(2.2)
    body = _babble(n, rng, tilt_hz=760, bright=1.05, voices=6)
    body = peaking(body, 330, 0.9, 4.5)
    env = env_ar(n, attack_s=0.07, release_s=1.5)
    body = [v * e * 1.25 for v, e in zip(body, env)]
    claps = _claps(n, rng, lambda p: 55 * math.exp(-1.5 * p), amp=0.5)
    return mix(gain(body, 1.0), gain(claps, 0.8))


def render_crowd_gasp(rng: random.Random) -> list[float]:
    """A near miss. Up sharply, then a hush — the sound of a stadium holding its breath.

    The DROP is the sound, not the rise: a gasp that decays like a cheer is a cheer.
    """
    n = seconds(1.1)
    body = _babble(n, rng, tilt_hz=1150, bright=1.25, voices=4)
    env = [0.0] * n
    peak = int(n * 0.16)
    for i in range(n):
        if i < peak:
            env[i] = (i / peak) ** 0.7
        else:
            p = (i - peak) / (n - peak)
            env[i] = math.exp(-p * 5.5) * 0.85 + 0.06 * (1 - p)
    return [v * e for v, e in zip(body, env)]


def render_crowd_groan(rng: random.Random) -> list[float]:
    """Your wicket, or a lost match. Low, slow, descending — disappointment, not anger."""
    n = seconds(1.8)
    body = _babble(n, rng, tilt_hz=470, bright=0.7, voices=5)
    body = lowpass(body, 1500)
    env = env_ar(n, attack_s=0.22, release_s=1.25)
    return [v * e for v, e in zip(body, env)]


def render_crowd_applause(rng: random.Random) -> list[float]:
    """Innings break: scattered applause, tapering over about two seconds.

    Dense clap grains with an exponentially falling rate. Applause is one of the few sounds
    that a Poisson process models almost exactly, because that is genuinely what it is —
    thousands of independent events with no shared clock.
    """
    n = seconds(2.1)
    claps = _claps(n, rng, lambda p: 90 * math.exp(-2.4 * p) + 4, amp=0.55)
    bed = _babble(n, rng, tilt_hz=820, bright=0.95, voices=4)
    bed = [v * e for v, e in zip(bed, env_ar(n, 0.1, 1.4))]
    return mix(gain(claps, 1.0), gain(bed, 0.35))


# =======================================================================================
# §4.4 — Rock Paper Scissors. Hand sounds: cloth, skin, air.
# =======================================================================================

def render_hand_pump(rng: random.Random) -> list[float]:
    """The fist-pump whoosh, one of the three countdown beats.

    Air moving past a hand is a noise band whose centre frequency rises and falls with the
    speed of the motion — so the model is a swept bandpass, not a static one. The caller
    plays this three times with a rising pitch, which reads as three progressively harder
    pumps.
    """
    n = seconds(0.20)
    src = white(n, rng)
    # Sweeping the filter properly would mean a time-varying biquad; three fixed bands with
    # staggered envelopes gets the same rising-then-falling impression far more cheaply.
    layers = []
    for f, t0, t1 in ((620, 0.00, 0.55), (1250, 0.18, 0.80), (2100, 0.42, 1.00)):
        band = bandpass(src, f, q=1.1)
        seg = [0.0] * n
        a, b = int(n * t0), int(n * t1)
        span = max(b - a, 1)
        for i in range(a, min(b, n)):
            p = (i - a) / span
            seg[i] = band[i] * math.sin(math.pi * p) ** 1.2
        layers.append(seg)
    cloth = lowpass(gain(white(n, rng), 0.25), 3000)
    cloth = [v * e for v, e in zip(cloth, env_ar(n, 0.03, 0.12))]
    return mix(*layers, cloth)


def render_hand_reveal(rng: random.Random) -> list[float]:
    """Both throws land on this one frame: a short cloth-and-air snap."""
    n = seconds(0.15)
    snap = bandpass(white(n, rng), 1750, q=0.8)
    snap = [v * e for v, e in zip(snap, env_exp(n, 13, attack_s=0.0008))]
    air = bandpass(white(n, rng), 620, q=0.7)
    air = [v * e for v, e in zip(air, env_exp(n, 7, attack_s=0.004))]
    return mix(gain(snap, 1.0), gain(air, 0.45))


# =======================================================================================
# Catalogue
# =======================================================================================

CATALOGUE: list[Physical] = [
    Physical("catch", "shared", render_catch,
             note="The shared sound. Played unmodified in all four games (SOUND_DESIGN §3)."),

    *[Physical(f"chalk_x_{i+1}", "tictactoe", render_chalk_x(i),
               note="X = two strokes with a gap. Hearable as two lines.")
      for i in range(3)],
    *[Physical(f"chalk_o_{i+1}", "tictactoe", render_chalk_o(i),
               note="O = one continuous sweep. No internal break.")
      for i in range(3)],
    Physical("chalk_line", "tictactoe", render_chalk_line,
             max_s=0.34,
             note="Matched to the 340 ms win-stroke animation. Must not outlast it."),
    Physical("chalk_stub", "tictactoe", render_chalk_stub, note="Illegal move."),
    Physical("chalk_erase", "tictactoe", render_chalk_erase, max_s=0.7, note="Draw."),

    Physical("wicket_timber", "cricket", render_wicket_timber,
             highpass_80=False, max_s=0.6,
             note="§6.2 exempt: the weight of this impact lives below 80 Hz."),
    Physical("bat_crack", "cricket", render_bat_crack, note="Four and six."),
    Physical("bat_soft", "cricket", render_bat_soft, note="1-3 runs."),
    Physical("bat_block", "cricket", render_bat_block, highpass_80=False,
             note="Dot ball. Deliberately anticlimactic."),

    Physical("crowd_base", "cricket", render_crowd_base, lufs=LUFS_BED,
             max_s=CROWD_BED_S, aac_only=True,
             note="22 s seamless bed. Gain-ramped by the client, never retriggered."),
    Physical("crowd_cheer", "cricket", render_crowd_cheer, max_s=1.8),
    Physical("crowd_roar", "cricket", render_crowd_roar, max_s=2.3),
    Physical("crowd_gasp", "cricket", render_crowd_gasp, max_s=1.2),
    Physical("crowd_groan", "cricket", render_crowd_groan, max_s=1.9),
    Physical("crowd_applause", "cricket", render_crowd_applause, max_s=2.2),

    Physical("hand_pump", "rps", render_hand_pump),
    Physical("hand_reveal", "rps", render_hand_reveal),
]


# =======================================================================================
# Mastering and output
# =======================================================================================

def master(sound: Physical, xs: list[float]) -> list[float]:
    """§6, applied uniformly to every sound, at the end, over the complete set.

    Order matters. Trim first so silence cannot skew the loudness measurement; high-pass
    before normalising so removing that energy does not then leave the file quiet; cap the
    length before the final measure so a tail that is about to be cut is not counted.
    """
    xs = trim_silence(xs)
    if sound.highpass_80:
        xs = highpass(xs, HP_CUTOFF, q=0.7)
    xs = cap_length(xs, sound.max_s)
    xs = trim_silence(xs)
    return normalize_lufs(xs, sound.lufs)


def to_pcm16(xs: list[float]) -> array.array:
    out = array.array("h")
    for v in xs:
        out.append(int(max(-1.0, min(1.0, v)) * 32767))
    return out


def write_wav(path: str, samples: array.array) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "w") as w:
        w.setnchannels(1)       # MONO. See this file's header — stereo is a hard crash.
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(samples.tobytes())


def encode_aac(wav_path: str, m4a_path: str, kbps: int) -> bool:
    """afconvert is macOS-only; skip quietly elsewhere and ship the WAV."""
    if shutil.which("afconvert") is None:
        return False
    subprocess.run(
        ["afconvert", "-f", "m4af", "-d", "aac", "-b", str(kbps * 1000),
         "-c", "1", wav_path, m4a_path],
        check=True, capture_output=True,
    )
    return True


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--game", choices=["shared", "tictactoe", "cricket", "rps"])
    ap.add_argument("--only", help="comma-separated sound names")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--seed", type=int, default=11)
    args = ap.parse_args()

    sounds = CATALOGUE
    if args.game:
        sounds = [s for s in sounds if s.game == args.game]
    if args.only:
        wanted = {n.strip() for n in args.only.split(",")}
        sounds = [s for s in sounds if s.name in wanted]

    if args.list:
        for s in sounds:
            print(f"{s.game:10s} {s.name:16s} {s.lufs:6.1f} LUFS  {s.note}")
        print(f"\n{len(sounds)} sounds")
        return

    aac = shutil.which("afconvert") is not None
    if not aac:
        print("afconvert not found (non-macOS host) — WAV only. The crowd bed will be "
              "large; re-run on macOS before shipping.")

    total_ios = total_android = 0
    for s in sounds:
        # Seeded PER SOUND NAME, so regenerating one file cannot change any other and a
        # rebuild is byte-identical. A catalogue whose output shifts every run is a
        # catalogue nobody can review as a diff.
        rng = random.Random(f"{args.seed}:{s.name}")
        raw = s.render(rng)
        mastered = master(s, raw)
        pcm = to_pcm16(mastered)

        dur = len(pcm) / SR
        measured = loudness_lufs(mastered)
        peak_db = 20 * math.log10(max((abs(v) for v in mastered), default=1e-9))

        # §7's format table, applied for real rather than aspirationally: short one-shots stay
        # WAV (instant, no decode), anything over 500 ms ships as AAC ONLY. Emitting both, as
        # this repo did before, bundles a WAV nothing ever loads — GameAudio resolves .wav
        # first and only falls back to .m4a.
        wav_ios = os.path.join(IOS_OUT, f"{s.name}.wav")
        m4a_ios = os.path.join(IOS_OUT, f"{s.name}.m4a")
        write_wav(wav_ios, pcm)
        os.makedirs(ANDROID_OUT, exist_ok=True)
        tag = ""

        long_form = s.aac_only or dur > AAC_THRESHOLD_S
        if long_form and aac:
            # 64 kbps mono for the bed (§7): 22 s is 1.9 MB as WAV and 180 KB as AAC against
            # a 4 MB per-platform budget. 96 for the rest, where size is not the constraint.
            encode_aac(wav_ios, m4a_ios, 64 if s.aac_only else 96)
            os.remove(wav_ios)          # the WAV was only ever the encoder's input
            ios_bytes = os.path.getsize(m4a_ios)
            tag = " [m4a]"
        else:
            if os.path.exists(m4a_ios):
                os.remove(m4a_ios)      # a shortened sound must not leave a stale long one
            ios_bytes = os.path.getsize(wav_ios)

        # ANDROID KEEPS WAV except for the bed. SoundPool decodes WAV happily and res/raw
        # cannot hold two files sharing a base name, so there is no both-formats option here
        # — and the bed does not go through SoundPool at all (see GameAudio.startBed).
        wav_android = os.path.join(ANDROID_OUT, f"{s.name}.wav")
        m4a_android = os.path.join(ANDROID_OUT, f"{s.name}.m4a")
        if s.aac_only and aac:
            shutil.copyfile(m4a_ios, m4a_android)
            if os.path.exists(wav_android):
                os.remove(wav_android)
            android_bytes = os.path.getsize(m4a_android)
            tag += " [android: m4a]"
        else:
            write_wav(wav_android, pcm)
            if os.path.exists(m4a_android):
                os.remove(m4a_android)
            android_bytes = os.path.getsize(wav_android)

        total_ios += ios_bytes
        total_android += android_bytes
        print(f"  {s.game:10s} {s.name:16s} {dur*1000:7.0f} ms  "
              f"{measured:6.1f} LUFS  peak {peak_db:5.1f} dBFS  "
              f"{ios_bytes/1024:6.1f} KB{tag}")

    print(f"\n{len(sounds)} sounds — iOS {total_ios/1024:.0f} KB, "
          f"Android {total_android/1024:.0f} KB (budget: 4096 KB per platform, §7)")


if __name__ == "__main__":
    main()
