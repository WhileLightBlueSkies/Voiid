#!/usr/bin/env python3
"""
Shared DSP toolkit for the Voiid game sounds — stdlib only, no dependencies.

`synth.py` renders the ABSTRACT palette from oscillator primitives (sine/saw/square).
That vocabulary cannot produce a crowd, a chalk scrape or a ball hitting stumps, because
those are not tonal events — they are noise processes and resonating bodies. This module
supplies what they need instead: filters, modal resonators, grain trains, a small room, and
the loudness maths for the mastering pass.

Everything here is float-in/float-out over plain Python lists. It is slow by C standards and
completely fast enough: the whole catalogue renders offline, by hand, once per change.
"""
from __future__ import annotations

import math
import random

SR = 44100


# --- biquads (RBJ cookbook) -----------------------------------------------------------

class Biquad:
    """Direct-form-I biquad. Stateful, so one instance filters one signal, once."""

    def __init__(self, b0: float, b1: float, b2: float, a1: float, a2: float):
        self.b0, self.b1, self.b2, self.a1, self.a2 = b0, b1, b2, a1, a2
        self.x1 = self.x2 = self.y1 = self.y2 = 0.0

    def process(self, xs: list[float]) -> list[float]:
        b0, b1, b2, a1, a2 = self.b0, self.b1, self.b2, self.a1, self.a2
        x1, x2, y1, y2 = self.x1, self.x2, self.y1, self.y2
        out = [0.0] * len(xs)
        for i, x in enumerate(xs):
            y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            out[i] = y
            x2, x1 = x1, x
            y2, y1 = y1, y
        self.x1, self.x2, self.y1, self.y2 = x1, x2, y1, y2
        return out


def _rbj(kind: str, f0: float, q: float, gain_db: float = 0.0, sr: int = SR) -> Biquad:
    w0 = 2 * math.pi * f0 / sr
    cos_w0, sin_w0 = math.cos(w0), math.sin(w0)
    alpha = sin_w0 / (2 * q)
    A = 10 ** (gain_db / 40)

    if kind == "lowpass":
        b0, b1, b2 = (1 - cos_w0) / 2, 1 - cos_w0, (1 - cos_w0) / 2
        a0, a1, a2 = 1 + alpha, -2 * cos_w0, 1 - alpha
    elif kind == "highpass":
        b0, b1, b2 = (1 + cos_w0) / 2, -(1 + cos_w0), (1 + cos_w0) / 2
        a0, a1, a2 = 1 + alpha, -2 * cos_w0, 1 - alpha
    elif kind == "bandpass":            # constant peak gain
        b0, b1, b2 = alpha, 0.0, -alpha
        a0, a1, a2 = 1 + alpha, -2 * cos_w0, 1 - alpha
    elif kind == "peaking":
        b0, b1, b2 = 1 + alpha * A, -2 * cos_w0, 1 - alpha * A
        a0, a1, a2 = 1 + alpha / A, -2 * cos_w0, 1 - alpha / A
    elif kind == "highshelf":
        sq = 2 * math.sqrt(A) * alpha
        b0 = A * ((A + 1) + (A - 1) * cos_w0 + sq)
        b1 = -2 * A * ((A - 1) + (A + 1) * cos_w0)
        b2 = A * ((A + 1) + (A - 1) * cos_w0 - sq)
        a0 = (A + 1) - (A - 1) * cos_w0 + sq
        a1 = 2 * ((A - 1) - (A + 1) * cos_w0)
        a2 = (A + 1) - (A - 1) * cos_w0 - sq
    else:
        raise ValueError(kind)

    return Biquad(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)


def lowpass(xs: list[float], f0: float, q: float = 0.707) -> list[float]:
    return _rbj("lowpass", f0, q).process(xs)


def highpass(xs: list[float], f0: float, q: float = 0.707) -> list[float]:
    return _rbj("highpass", f0, q).process(xs)


def bandpass(xs: list[float], f0: float, q: float = 1.0) -> list[float]:
    return _rbj("bandpass", f0, q).process(xs)


def peaking(xs: list[float], f0: float, q: float, gain_db: float) -> list[float]:
    return _rbj("peaking", f0, q, gain_db).process(xs)


# --- sources and envelopes ------------------------------------------------------------

def white(n: int, rng: random.Random) -> list[float]:
    return [rng.uniform(-1.0, 1.0) for _ in range(n)]


def silence(n: int) -> list[float]:
    return [0.0] * n


def seconds(dur: float) -> int:
    return int(SR * dur)


def env_exp(n: int, k: float, attack_s: float = 0.002) -> list[float]:
    """Fast attack, exponential decay — the shape of essentially every physical impact.

    The attack is not instantaneous on purpose: a true step edge is a click with its own
    spectrum, and on a phone speaker that click is the loudest thing in the file.
    """
    a = max(int(SR * attack_s), 1)
    out = [0.0] * n
    for i in range(n):
        p = i / n if n else 0.0
        amp = math.exp(-p * k)
        if i < a:
            amp *= i / a
        out[i] = amp
    return out


def env_ar(n: int, attack_s: float, release_s: float) -> list[float]:
    """Linear attack, cosine release. For swells (a crowd rising), not impacts."""
    a = max(int(SR * attack_s), 1)
    r = max(int(SR * release_s), 1)
    out = [0.0] * n
    for i in range(n):
        if i < a:
            out[i] = i / a
        elif i > n - r:
            p = (i - (n - r)) / r
            out[i] = 0.5 * (1 + math.cos(math.pi * min(p, 1.0)))
        else:
            out[i] = 1.0
    return out


def modal(n: int, modes: list[tuple[float, float, float]], rng: random.Random) -> list[float]:
    """A struck resonating body: a sum of exponentially decaying sinusoids.

    `modes` is (frequency Hz, decay time constant s, amplitude). This IS what a piece of
    wood does when you hit it — a handful of modes, each ringing at its own rate — and it
    is why a modal bank sounds like timber where a filtered noise burst sounds like static.

    Phases are randomised per mode so two strikes of the same body are not bit-identical.
    """
    out = [0.0] * n
    for f, tau, amp in modes:
        phase = rng.uniform(0, 2 * math.pi)
        w = 2 * math.pi * f / SR
        d = math.exp(-1.0 / (tau * SR))
        a = amp
        for i in range(n):
            out[i] += a * math.sin(w * i + phase)
            a *= d
            if a < 1e-6:
                break
    return out


def grain_train(
    n: int,
    rate_at: "callable",
    rng: random.Random,
    grain_s: float = 0.0016,
    jitter: float = 0.55,
) -> list[float]:
    """An amplitude envelope made of dense micro-impacts — the STICK-SLIP process.

    Chalk on slate is not a continuous scrape. The chalk grabs the surface, the stick
    releases, it grabs again, hundreds of times a second; the sound is that impact train,
    and its rate is what tells you how fast the hand is moving. Modelling it as a grain
    envelope over resonant noise is what makes it read as chalk rather than as hiss.

    `rate_at(p)` returns grains per second at progress p, so a stroke can accelerate.
    """
    out = [0.0] * n
    glen = max(int(SR * grain_s), 2)
    i = 0
    while i < n:
        p = i / n if n else 0.0
        amp = rng.uniform(1.0 - jitter, 1.0)
        for j in range(min(glen, n - i)):
            # Cosine grain: no edge discontinuity, so the train has no buzz of its own.
            out[i + j] += amp * 0.5 * (1 - math.cos(2 * math.pi * j / glen))
        rate = max(rate_at(p), 1.0)
        step = SR / rate
        i += max(int(step * rng.uniform(0.55, 1.45)), 1)
    return [min(v, 1.0) for v in out]


def poisson_impulses(n: int, density_at: "callable", rng: random.Random) -> list[int]:
    """Impulse times for sparse random events (claps in applause, bails rattling).

    A Poisson process rather than a fixed grid: evenly spaced claps read as a drum machine,
    and the whole point of a crowd is that nobody is in time with anybody.
    """
    out: list[int] = []
    i = 0
    while i < n:
        p = i / n if n else 0.0
        d = max(density_at(p), 0.01)
        gap = -math.log(max(rng.random(), 1e-9)) / d
        i += max(int(gap * SR), 1)
        if i < n:
            out.append(i)
    return out


# --- a small room ----------------------------------------------------------------------

def room(xs: list[float], mix: float = 0.25, size: float = 1.0, damp: float = 0.35) -> list[float]:
    """Schroeder reverb — four parallel combs into two series allpasses.

    Deliberately SMALL and short. Every sound in this app is heard on a phone speaker in a
    noisy room, where a long tail does not read as space, it reads as mud and eats the next
    event. Cricket gets its space from the crowd bed sitting under it, not from here.
    """
    comb_ms = [29.7, 37.1, 41.1, 43.7]
    ap_ms = [5.0, 1.7]
    n = len(xs)
    acc = [0.0] * n

    for ms in comb_ms:
        delay = max(int(SR * ms * size / 1000), 1)
        buf = [0.0] * delay
        idx = 0
        store = 0.0
        fb = 0.78
        for i in range(n):
            out = buf[idx]
            acc[i] += out
            store = out * (1 - damp) + store * damp
            buf[idx] = xs[i] + store * fb
            idx = (idx + 1) % delay

    for ms in ap_ms:
        delay = max(int(SR * ms / 1000), 1)
        buf = [0.0] * delay
        idx = 0
        g = 0.5
        for i in range(n):
            bufout = buf[idx]
            out = -acc[i] + bufout
            buf[idx] = acc[i] + bufout * g
            acc[i] = out
            idx = (idx + 1) % delay

    return [xs[i] * (1 - mix) + acc[i] * mix * 0.25 for i in range(n)]


# --- loop preparation ------------------------------------------------------------------

def loop_crossfade(xs: list[float], fade_s: float = 0.75) -> list[float]:
    """Make a buffer seamlessly loopable by wrapping its tail back over its head.

    A crowd loop with an audible seam is worse than no crowd: the ear locks onto the repeat
    inside about three cycles, and from then on the stadium is a metronome. The last
    `fade_s` is faded out while the same span faded IN is mixed over the beginning, so the
    end of the buffer and its start are literally the same signal, and playback wraps
    through a continuous waveform rather than a discontinuity.
    """
    n = len(xs)
    f = min(int(SR * fade_s), n // 3)
    out = list(xs[:n - f])
    for i in range(f):
        w = i / f
        out[i] = out[i] * w + xs[n - f + i] * (1 - w)
    return out


# --- loudness (ITU-R BS.1770 K-weighting) ----------------------------------------------

def k_weight(xs: list[float]) -> list[float]:
    """BS.1770's two-stage pre-filter: a head-shadow high shelf, then a 38 Hz high-pass."""
    stage1 = _rbj("highshelf", 1681.97, 0.7071752, 3.99984).process(xs)
    return _rbj("highpass", 38.13, 0.5003271).process(stage1)


def loudness_lufs(xs: list[float]) -> float:
    """K-weighted loudness of the WHOLE file, in LUFS.

    NOT ITU gated integrated loudness. The gating in BS.1770 operates on 400 ms blocks, and
    most of this catalogue is shorter than one block — for a 180 ms slap the gated measure
    is undefined rather than merely inaccurate. Measuring the mean square across the file
    with the same K-weighting keeps the perceptual weighting (which is the part that makes
    different sounds match) and drops only the part that cannot apply. Documented here
    because "-16 LUFS" would otherwise imply a measurement nobody could reproduce.
    """
    y = k_weight(xs)
    ms = sum(v * v for v in y) / len(y) if y else 0.0
    if ms <= 1e-12:
        return -120.0
    return -0.691 + 10 * math.log10(ms)


def soft_limit(xs: list[float], ceiling: float) -> list[float]:
    """Tanh soft clipper — round the peaks off instead of scaling the whole file down.

    WITHOUT THIS, LOUDNESS MATCHING DOES NOT WORK FOR TRANSIENTS. A leather slap has a huge
    crest factor: bring its peak to -1 dBFS and its loudness lands 6 dB under a chalk scrape
    that measures the same on a meter but is nowhere near as spiky. Scaling is the wrong
    lever, because the problem is the shape of the peak, not the level of the file.

    Tanh is the gentle version of what analogue circuitry does at the top of its range: it
    compresses the last few dB continuously rather than shearing them off, so there is no
    hard corner to alias. On a percussive attack a few dB of it is inaudible, and past that
    it starts to dull the transient — which is why `normalize_lufs` bounds how much it will
    ask for rather than driving until the number is right.
    """
    if ceiling <= 0:
        return xs
    return [ceiling * math.tanh(v / ceiling) for v in xs]


def normalize_lufs(
    xs: list[float],
    target: float,
    ceiling_dbfs: float = -1.0,
    max_limit_db: float = 6.0,
) -> list[float]:
    """Loudness-match to `target`, holding a peak ceiling, limiting rather than scaling.

    NOT PEAK NORMALISATION. Peak-normalising is exactly what makes one sound feel twice as
    loud as another at the same numeric level: a crowd bed and a chalk tap can share a peak
    and be 20 dB apart to the ear. The ceiling is a second, separate guarantee — playback
    applies varispeed, and a file already at 0 dBFS clips the moment it is pitched.

    `max_limit_db` bounds how hard the limiter is driven. A sound too spiky to reach target
    within that budget is left QUIETER THAN TARGET on purpose: squashing a bat crack flat to
    win 3 dB on a meter trades the thing that makes it a crack for a number.
    """
    current = loudness_lufs(xs)
    if current <= -119:
        return xs

    ceiling = 10 ** (ceiling_dbfs / 20)
    drive_limit = 10 ** (max_limit_db / 20)

    out = [v * 10 ** ((target - current) / 20) for v in xs]
    peak = max((abs(v) for v in out), default=0.0)

    if peak > ceiling:
        # Never ask the limiter for more than max_limit_db of reduction; scale off whatever
        # overshoot is left so the ceiling is still guaranteed.
        if peak > ceiling * drive_limit:
            out = [v * (ceiling * drive_limit / peak) for v in out]
        out = soft_limit(out, ceiling)

        # Limiting costs loudness. One bounded correction pass recovers most of it; looping
        # to convergence would just re-limit what it just gained.
        after = loudness_lufs(out)
        if after > -119:
            correction = min(10 ** ((target - after) / 20), drive_limit)
            out = soft_limit([v * correction for v in out], ceiling)

    return out


# --- trimming and utility ---------------------------------------------------------------

def trim_silence(xs: list[float], threshold: float = 0.0025, keep_head_ms: float = 1.0) -> list[float]:
    """Cut leading and trailing near-silence.

    Leading silence IS perceived latency, and this app has an audio engine deliberately
    tuned for sub-frame trigger latency — a 40 ms lead-in would silently throw that away at
    exactly the moment something exciting happened. A hair of head is kept so the attack
    still starts from zero rather than from a step.
    """
    start, end = 0, len(xs)
    while start < end and abs(xs[start]) < threshold:
        start += 1
    while end > start and abs(xs[end - 1]) < threshold:
        end -= 1
    if start >= end:
        return xs
    head = min(int(SR * keep_head_ms / 1000), start)
    return xs[start - head:end]


def cap_length(xs: list[float], max_s: float, fade_s: float = 0.02) -> list[float]:
    """Hard length cap with a short fade, so a cut never leaves a click."""
    n = int(SR * max_s)
    if len(xs) <= n:
        return xs
    out = xs[:n]
    f = min(int(SR * fade_s), n)
    for i in range(f):
        out[n - f + i] *= 1 - i / f
    return out


def mix(*layers: list[float]) -> list[float]:
    n = max((len(x) for x in layers), default=0)
    out = [0.0] * n
    for layer in layers:
        for i, v in enumerate(layer):
            out[i] += v
    return out


def gain(xs: list[float], g: float) -> list[float]:
    return [v * g for v in xs]


def at(xs: list[float], offset_s: float, length: int) -> list[float]:
    """Place `xs` at `offset_s` inside a buffer of `length` samples."""
    out = [0.0] * length
    o = int(SR * offset_s)
    for i, v in enumerate(xs):
        if 0 <= o + i < length:
            out[o + i] += v
    return out
