"""
Video processing for series_1_5_pipeline.py.

Turns a horizontal film into portrait episodes the Voiid Clips player accepts:
  - each episode <= 88s (server cap is 90s: MAX_DURATION_MS in backend/api/src/routes/clips.ts)
  - 1080x1920, film centred over a blurred copy of itself
  - series title (whole episode), rating card (first 4s), credit line (whole episode)
  - 720p and 480p renditions matching ClipQuality.kt / ClipQuality.swift
  - a 540x960 JPEG cover

Needs ffmpeg with drawtext (libfreetype) and libx264: `brew install ffmpeg-full`.
Python 3.9+, standard library only.
"""
import json
import os
import re
import shutil
import subprocess
import textwrap
from typing import List, Tuple

MAX_EPISODE_S = 88.0
TARGET_EPISODE_S = 80.0
MIN_EPISODE_S = 55.0
MIN_TAIL_S = 20.0
RATING_CARD_S = 4.0
THUMB_AT_S = 5.0  # after the rating card has gone

# name: (width, height, video kbps). Long edges match the apps' ClipQuality ladder.
RENDITIONS = {
    "fhd": (1080, 1920, 4500),
    "hd": (720, 1280, 2800),
    "sd": (480, 854, 1200),
}

FFMPEG_FULL_DIRS = ["/opt/homebrew/opt/ffmpeg-full/bin", "/usr/local/opt/ffmpeg-full/bin"]
FONT_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]
# Characters that would break an ffmpeg filtergraph option, even inside quotes.
UNSAFE_FILTER_CHARS = re.compile(r"['\\:;,\[\]=]")


class VideoError(RuntimeError):
    pass


def run(cmd: List[str]) -> str:
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          universal_newlines=True)
    if proc.returncode != 0:
        tail = "\n".join(proc.stdout.splitlines()[-25:])
        raise VideoError("%s failed:\n%s" % (os.path.basename(cmd[0]), tail))
    return proc.stdout


def find_tools() -> Tuple[str, str]:
    """ffmpeg-full is keg-only, so look in its opt dir before PATH."""
    ffmpeg = os.environ.get("FFMPEG_BIN")
    ffprobe = os.environ.get("FFPROBE_BIN")
    if not ffmpeg:
        for d in FFMPEG_FULL_DIRS:
            if os.path.exists(os.path.join(d, "ffmpeg")):
                ffmpeg = os.path.join(d, "ffmpeg")
                ffprobe = ffprobe or os.path.join(d, "ffprobe")
                break
    ffmpeg = ffmpeg or shutil.which("ffmpeg")
    ffprobe = ffprobe or shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        raise VideoError("ffmpeg not found. Install it with: brew install ffmpeg-full")

    filters = run([ffmpeg, "-hide_banner", "-filters"])
    for name in ("drawtext", "drawbox", "boxblur", "overlay", "eq"):
        if not re.search(r"\s%s\s" % name, filters):
            raise VideoError("ffmpeg at %s has no '%s' filter. Install: brew install ffmpeg-full" % (ffmpeg, name))
    if "libx264" not in run([ffmpeg, "-hide_banner", "-encoders"]):
        raise VideoError("ffmpeg at %s has no libx264 encoder. Install: brew install ffmpeg-full" % ffmpeg)
    return ffmpeg, ffprobe


def find_font() -> str:
    override = os.environ.get("VOIID_FONT_FILE")
    for path in ([override] if override else []) + FONT_CANDIDATES:
        if path and os.path.exists(path):
            if UNSAFE_FILTER_CHARS.search(path):
                raise VideoError("font path has characters ffmpeg can't take: %s" % path)
            return path
    raise VideoError("no font found; set VOIID_FONT_FILE to a .ttf file")


def probe(ffprobe: str, path: str) -> dict:
    out = run([ffprobe, "-v", "error", "-print_format", "json", "-show_format", "-show_streams", path])
    data = json.loads(out)
    video = next((s for s in data["streams"] if s.get("codec_type") == "video"), None)
    if video is None:
        raise VideoError("no video stream in %s" % path)
    return {
        "duration": float(data["format"]["duration"]),
        "width": int(video["width"]),
        "height": int(video["height"]),
        "has_audio": any(s.get("codec_type") == "audio" for s in data["streams"]),
    }


def scene_changes(ffmpeg: str, path: str, threshold: float = 0.35) -> List[float]:
    """Timestamps (seconds) where the picture changes a lot: candidate episode cuts."""
    out = run([ffmpeg, "-hide_banner", "-nostats", "-i", path, "-an",
               "-vf", "scale=320:-2,select='gt(scene,%s)',showinfo" % threshold,
               "-f", "null", "-"])
    return sorted(float(t) for t in re.findall(r"pts_time:([0-9.]+)", out))


def plan_episodes(duration: float, scenes: List[float]) -> List[Tuple[float, float]]:
    """Split [0, duration] into episodes of MIN..MAX seconds, cutting on scene changes."""
    episodes = []
    start = 0.0
    while duration - start > MAX_EPISODE_S:
        low, high, ideal = start + MIN_EPISODE_S, start + MAX_EPISODE_S, start + TARGET_EPISODE_S
        near = [t for t in scenes if low <= t <= high]
        cut = min(near, key=lambda t: abs(t - ideal)) if near else ideal
        # Avoid a stub final episode when an earlier cut still keeps this one long enough.
        if duration - cut < MIN_TAIL_S and (duration - MIN_TAIL_S) - start >= MIN_EPISODE_S:
            cut = duration - MIN_TAIL_S
        episodes.append((start, cut))
        start = cut
    episodes.append((start, duration))
    return episodes


def _write_text(path: str, text: str, width: int) -> str:
    wrapped = "\n".join(textwrap.fill(line, width=width) if line else "" for line in text.split("\n"))
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(wrapped)
    if UNSAFE_FILTER_CHARS.search(path) or " " in path:
        raise VideoError("work path has characters ffmpeg can't take: %s" % path)
    return path


def render_episode(ffmpeg: str, src: str, start: float, end: float, out_dir: str,
                   title: str, rating_line: str, credit: str, font: str) -> str:
    """Render the 1080x1920 master. Returns its path."""
    os.makedirs(out_dir, exist_ok=True)
    title_file = _write_text(os.path.join(out_dir, "title.txt"), title, 34)
    rating_file = _write_text(os.path.join(out_dir, "rating.txt"), rating_line, 30)
    credit_file = _write_text(os.path.join(out_dir, "credit.txt"), credit, 48)
    out = os.path.join(out_dir, "fhd.mp4")

    graph = (
        "[0:v]split=2[a][b];"
        "[a]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,"
        "boxblur=24:3,eq=brightness=-0.08[bg];"
        "[b]scale=1080:-2[fg];"
        "[bg][fg]overlay=(W-w)/2:(H-h)/2,"
        "drawtext=fontfile='{font}':textfile='{title}':fontcolor=white:fontsize=50:"
        "line_spacing=8:x=(w-text_w)/2:y=170,"
        "drawtext=fontfile='{font}':textfile='{rating}':fontcolor=white:fontsize=54:"
        "box=1:boxcolor=black@0.65:boxborderw=28:x=(w-text_w)/2:y=330:enable='lt(t,{card})',"
        "drawtext=fontfile='{font}':textfile='{credit}':fontcolor=white:fontsize=28:"
        "line_spacing=8:box=1:boxcolor=black@0.45:boxborderw=14:x=(w-text_w)/2:y=h-text_h-320,"
        "format=yuv420p[v]"
    ).format(font=font, title=title_file, rating=rating_file, credit=credit_file, card=RATING_CARD_S)

    width, height, kbps = RENDITIONS["fhd"]
    run([ffmpeg, "-hide_banner", "-nostats", "-loglevel", "error", "-y",
         "-ss", "%.3f" % start, "-t", "%.3f" % (end - start), "-i", src,
         "-filter_complex", graph, "-map", "[v]", "-map", "0:a?",
         "-c:v", "libx264", "-preset", "slow", "-profile:v", "high",
         "-b:v", "%dk" % kbps, "-maxrate", "%dk" % int(kbps * 1.1), "-bufsize", "%dk" % (kbps * 2),
         "-c:a", "aac", "-b:a", "128k", "-ar", "48000", "-ac", "2",
         "-movflags", "+faststart", out])
    return out


def make_renditions(ffmpeg: str, master: str, out_dir: str) -> dict:
    """fhd is the master itself; hd and sd are scaled down from it."""
    files = {"fhd": master}
    for name in ("hd", "sd"):
        width, height, kbps = RENDITIONS[name]
        out = os.path.join(out_dir, "%s.mp4" % name)
        run([ffmpeg, "-hide_banner", "-nostats", "-loglevel", "error", "-y", "-i", master,
             "-vf", "scale=%d:%d" % (width, height), "-map", "0:v", "-map", "0:a?",
             "-c:v", "libx264", "-preset", "slow", "-profile:v", "high", "-pix_fmt", "yuv420p",
             "-b:v", "%dk" % kbps, "-maxrate", "%dk" % int(kbps * 1.1), "-bufsize", "%dk" % (kbps * 2),
             "-c:a", "copy", "-movflags", "+faststart", out])
        files[name] = out
    return files


def make_thumb(ffmpeg: str, master: str, out_dir: str, duration: float) -> str:
    out = os.path.join(out_dir, "thumb.jpg")
    at = min(THUMB_AT_S, max(0.0, duration / 2))
    run([ffmpeg, "-hide_banner", "-nostats", "-loglevel", "error", "-y",
         "-ss", "%.2f" % at, "-i", master, "-frames:v", "1",
         "-vf", "scale=540:960", "-q:v", "4", out])
    return out
