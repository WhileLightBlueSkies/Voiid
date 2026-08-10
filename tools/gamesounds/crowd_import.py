#!/usr/bin/env python3
"""
Import the RECORDED cricket crowd (docs/games/SOUND_DESIGN.md §4.1, §5.3).

The crowd was the one place the synthesised palette genuinely lost. Chalk, timber and bat
contacts are impacts and resonating bodies, which physical models render convincingly; a
stadium is thousands of real voices with real room, and modelled noise reads as "fake" no
matter how carefully the bands are shaped. These three are real recordings, so they replace
`crowd_base`, `crowd_cheer`/`crowd_roar` and `crowd_groan` outright.

WHAT THIS FIXES ABOUT THE SOURCE FILES. All three arrive stereo (a hard AVAudioEngine crash on
the mono-wired bus), two at 48 kHz (silently refused at load), the cheer 30 s long, and all of
them mastered loud for standalone listening rather than to sit under a game.

    source                          -> shipped
    normal_crowd_sound.mp3          -> crowd_base      22 s seamless loop, -26 LUFS
    crowd-cheering-in-stadium.mp3   -> crowd_cheer     1.8 s  from the 9.3 s peak
                                    -> crowd_roar      2.4 s  bigger, from the same peak
                                    -> crowd_applause  2.2 s  from the 24.3 s re-swell
    crowd-booing.mp3                -> crowd_groan     1.8 s
                                    -> crowd_gasp      1.0 s  from its sharp onset

THE BED IS THE HARD ONE. The source decays steadily across its 8.2 s — it is a fade-out, not a
loop, and wrap-crossfading it as-is would pulse once per cycle at exactly the rate the ear
locks onto. So the decay is flattened first (see `flatten`), then the flat result is tiled to
22 s with overlapping crossfades, then wrap-crossfaded. Tiling is what buys a period long
enough not to be recognised out of 8 seconds of source.

Usage:
    python3 tools/gamesounds/crowd_import.py                 # from ~/Downloads
    python3 tools/gamesounds/crowd_import.py --src <dir>
"""
from __future__ import annotations

import argparse
import array
import math
import os
import shutil
import subprocess
import sys
import wave

from dsp import (
    SR, highpass, loop_crossfade, loudness_lufs, lowpass, normalize_lufs, seconds,
    trim_silence,
)
from physical import (
    ANDROID_OUT, IOS_OUT, LUFS_BED, LUFS_ONESHOT, encode_aac, to_pcm16, write_wav,
)

SOURCES = {
    "normal_crowd_sound.mp3": "bed",
    "crowd-cheering-in-stadium.mp3": "cheer",
    "crowd-booing.mp3": "boo",
}

BED_SECONDS = 22.0


def decode_mono_441(src: str, dst: str) -> None:
    """afconvert does the stereo->mono downmix and the 48k->44.1k resample in one pass.

    Both conversions are REQUIRED, not tidying. A stereo buffer scheduled onto GameAudio's
    mono-wired bus is an ObjC NSException that `try?` cannot catch — the process dies, and it
    is the crash this whole pipeline is careful about. A 48 kHz file does not crash; it is
    simply refused at load and the sound is silently missing, which is harder to notice.
    """
    subprocess.run(
        ["afconvert", "-f", "WAVE", "-d", "LEI16@44100", "-c", "1", src, dst],
        check=True, capture_output=True,
    )


def load_wav(path: str) -> list[float]:
    with wave.open(path, "rb") as w:
        assert w.getnchannels() == 1 and w.getframerate() == SR
        raw = w.readframes(w.getnframes())
    a = array.array("h")
    a.frombytes(raw)
    return [v / 32768.0 for v in a]


def rms_envelope(xs: list[float], win_s: float = 0.25) -> list[float]:
    w = max(int(SR * win_s), 1)
    return [
        math.sqrt(sum(v * v for v in xs[i:i + w]) / w)
        for i in range(0, max(len(xs) - w, 1), w)
    ]


def flatten(xs: list[float], win_s: float = 0.5, strength: float = 0.9) -> list[float]:
    """Remove a recording's overall level drift, keeping its short-term texture.

    The bed source fades across its whole length. Looping a fade means the crowd swells and
    collapses once per cycle, and a periodic swell is the single most recognisable artefact a
    loop can have — worse than an audible seam, because it repeats on a musical timescale.

    Divides by a heavily smoothed version of the envelope, so slow drift is cancelled while
    individual claps and shouts (which are much faster than the smoothing window) survive
    untouched. `strength` < 1 leaves a trace of the original dynamics so it does not read as
    compressed flat.
    """
    env = rms_envelope(xs, win_s)
    if not env:
        return xs
    target = sorted(env)[len(env) // 2] or 1e-6

    # Linearly interpolate the coarse envelope back up to sample rate — a per-block gain step
    # would click at every block boundary.
    w = max(int(SR * win_s), 1)
    out = [0.0] * len(xs)
    for i in range(len(xs)):
        b = i / w
        lo = min(int(b), len(env) - 1)
        hi = min(lo + 1, len(env) - 1)
        frac = b - lo
        local = env[lo] * (1 - frac) + env[hi] * frac
        gain = (target / max(local, 1e-6)) ** strength
        out[i] = xs[i] * min(gain, 4.0)
    return out


def tile_to(xs: list[float], total_s: float, fade_s: float = 0.6) -> list[float]:
    """Repeat `xs` up to `total_s`, crossfading each join.

    22 seconds out of 8 needs three passes. Butt-joining them would put a hard edge at every
    seam; overlapping with an equal-power crossfade makes each join a brief double-density
    moment, which in a crowd is indistinguishable from more people shouting at once.
    """
    n_total = seconds(total_s)
    f = int(SR * fade_s)
    out = list(xs)
    while len(out) < n_total:
        head = len(out) - f
        for i in range(f):
            w = i / f
            a = math.cos(w * math.pi / 2)      # equal power, not linear: a linear crossfade
            b = math.sin(w * math.pi / 2)      # dips in the middle on uncorrelated noise
            out[head + i] = out[head + i] * a + xs[i] * b
        out.extend(xs[f:])
    return out[:n_total]


def slice_at(xs: list[float], start_s: float, dur_s: float,
             fade_in_s: float = 0.02, fade_out_s: float = 0.35) -> list[float]:
    """Cut a reaction out of a long recording, with a fast in and a shaped tail.

    The fade-in is short — a crowd reaction has to arrive on the beat of the event, and
    anything slower reads as the app being late rather than the crowd being real. The fade-out
    is long, because that is what a real reaction does and a hard cut sounds like a dropout.
    """
    a = seconds(start_s)
    seg = xs[a:a + seconds(dur_s)]
    fi, fo = int(SR * fade_in_s), int(SR * fade_out_s)
    for i in range(min(fi, len(seg))):
        seg[i] *= i / fi
    for i in range(min(fo, len(seg))):
        seg[len(seg) - 1 - i] *= i / fo
    return seg


def voice_band(xs: list[float]) -> list[float]:
    """Sit the crowd where a phone speaker can actually put it, and where the game is not.

    Rolls off below 110 Hz (a phone reproduces none of it, and it only eats headroom the
    wicket needs) and above 3.4 kHz (distance and air absorption do this in reality; keeping
    it makes the crowd sound like it is standing next to the microphone instead of filling a
    stadium). The band left over is also deliberately clear of the bat and stump transients,
    so impacts still cut through a roaring crowd.
    """
    return lowpass(highpass(xs, 110, q=0.7), 3400, q=0.7)


def emit(name: str, samples: list[float], lufs: float, aac_only: bool = False) -> None:
    """Write one asset to both platforms, honouring §7's format table."""
    samples = normalize_lufs(samples, lufs)
    pcm = to_pcm16(samples)
    dur = len(pcm) / SR

    wav_ios = os.path.join(IOS_OUT, f"{name}.wav")
    m4a_ios = os.path.join(IOS_OUT, f"{name}.m4a")
    wav_android = os.path.join(ANDROID_OUT, f"{name}.wav")
    m4a_android = os.path.join(ANDROID_OUT, f"{name}.m4a")
    write_wav(wav_ios, pcm)

    long_form = aac_only or dur > 0.5
    if long_form:
        encode_aac(wav_ios, m4a_ios, 64 if aac_only else 96)
        os.remove(wav_ios)
        ios_bytes = os.path.getsize(m4a_ios)
        tag = "m4a"
    else:
        if os.path.exists(m4a_ios):
            os.remove(m4a_ios)
        ios_bytes = os.path.getsize(wav_ios)
        tag = "wav"

    # Android: the bed rides MediaPlayer and ships as AAC; everything else stays WAV for
    # SoundPool. res/raw cannot hold two files sharing a base name, so it is one or the other.
    if aac_only:
        shutil.copyfile(m4a_ios, m4a_android)
        if os.path.exists(wav_android):
            os.remove(wav_android)
        android_bytes = os.path.getsize(m4a_android)
    else:
        write_wav(wav_android, pcm)
        if os.path.exists(m4a_android):
            os.remove(m4a_android)
        android_bytes = os.path.getsize(wav_android)

    print(f"  {name:16s} {dur:6.2f}s  {loudness_lufs(samples):6.1f} LUFS  "
          f"ios {ios_bytes/1024:6.1f} KB [{tag}]  android {android_bytes/1024:6.1f} KB")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--src", default=os.path.expanduser("~/Downloads"))
    ap.add_argument("--work", default="/tmp/voiid-crowd")
    args = ap.parse_args()

    if shutil.which("afconvert") is None:
        sys.exit("afconvert not found — this importer is macOS-only.")

    os.makedirs(args.work, exist_ok=True)
    decoded = {}
    for fname, key in SOURCES.items():
        src = os.path.join(args.src, fname)
        if not os.path.exists(src):
            sys.exit(f"missing source: {src}")
        dst = os.path.join(args.work, key + ".wav")
        decode_mono_441(src, dst)
        decoded[key] = load_wav(dst)
        print(f"decoded {fname}: {len(decoded[key])/SR:.2f}s mono 44.1k")

    print("\nrendering:")

    # --- the bed ---------------------------------------------------------------------------
    bed = voice_band(flatten(decoded["bed"]))
    bed = tile_to(bed, BED_SECONDS)
    bed = loop_crossfade(bed, fade_s=1.2)
    emit("crowd_base", bed, LUFS_BED, aac_only=True)

    # --- reactions, from the cheer ----------------------------------------------------------
    # 9.3 s is where the recording's own biggest swell begins (measured, not guessed — see the
    # envelope profile in this file's header).
    cheer_src = voice_band(decoded["cheer"])
    emit("crowd_cheer", slice_at(cheer_src, 9.30, 1.75), LUFS_ONESHOT)
    emit("crowd_roar", slice_at(cheer_src, 9.10, 2.35, fade_out_s=0.6), LUFS_ONESHOT)
    # A separate, later swell so the innings break is not an obvious repeat of the six.
    emit("crowd_applause", slice_at(cheer_src, 24.25, 2.10, fade_out_s=0.5), LUFS_ONESHOT)

    # --- reactions, from the boo -------------------------------------------------------------
    boo_src = voice_band(decoded["boo"])
    emit("crowd_groan", slice_at(boo_src, 0.18, 1.80, fade_out_s=0.5), LUFS_ONESHOT)
    # A gasp is the ONSET only, cut before the boo becomes a sustained jeer: the drop is the
    # sound, and anything longer turns "ooh" into "boo", which is a different emotion.
    emit("crowd_gasp", slice_at(boo_src, 0.20, 1.00, fade_out_s=0.45), LUFS_ONESHOT)

    print("\nDone. Run tools/gamesounds/verify.py to confirm mono/rate/headroom/loudness.")


if __name__ == "__main__":
    main()
