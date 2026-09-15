#!/usr/bin/env python3
"""
series_1_5_pipeline.py: fetch, cut, format and post Voiid series 1-5 from the official account.

Per film:  Wikimedia Commons license check -> download -> cut into <=88s episodes at scene
           changes -> 1080x1920 with title, rating card and credit -> 720p/480p + cover -> records
Per episode: presigned R2 uploads -> POST /v1/clips (same flow as the apps' ClipService)

Runs unattended once set up. Read "00 - Start Here.md" before the first run.
Python 3.9+, standard library only. Needs ffmpeg-full: brew install ffmpeg-full
"""
import argparse
import base64
import csv
import datetime as dt
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import List, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import series_1_5_video as video  # noqa: E402

COMMONS_API = "https://commons.wikimedia.org/w/api.php"
USER_AGENT = os.environ.get("VOIID_USER_AGENT", "VoiidSeriesPipeline/1.0 (+https://voiid.app)")

# Official content stays at U or U/A 7+ ("Clips and Series Guideline and Changes.md", section 10).
POSTABLE_RATINGS = {
    "U": "Suitable for all ages",
    "U/A 7+": "Ages 7+; under 7 with parental guidance",
}
ALLOWED_LICENSES = {"CC0", "CC BY 3.0", "CC BY 4.0", "CC BY-SA 3.0", "CC BY-SA 4.0"}

# Server limits, mirrored from backend/api/src/routes/clips.ts.
MAX_DURATION_MS = 90000
MAX_BYTE_SIZE = 100 * 1024 * 1024
MAX_CAPTION_LEN = 2200
MAX_CLIPS_PER_DAY = 30

SAFE_WORK_DIR = re.compile(r"^[A-Za-z0-9._/~-]+$")
PLACEHOLDER_PREFIX = "SET "

_log_path = None  # type: Optional[str]


class Fatal(RuntimeError):
    """Stop the run; the message says what to fix."""


class QuotaHit(RuntimeError):
    """The server refused a post because of MAX_CLIPS_PER_DAY."""


# ── small helpers ────────────────────────────────────────────────────────────────

def log(message: str) -> None:
    line = "%s  %s" % (dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), message)
    print(line, flush=True)
    if _log_path:
        with open(_log_path, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def slugify(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def file_hash(path: str, algo: str = "sha256") -> str:
    digest = hashlib.new(algo)
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: str, data) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


def jwt_claims(token: str) -> dict:
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload.encode("ascii")))
    except (IndexError, ValueError):
        raise Fatal("VOIID_TOKEN doesn't look like a Voiid session token (JWT)")


# ── HTTP ─────────────────────────────────────────────────────────────────────────

def http_request(method: str, url: str, body=None, headers=None, retries: int = 4) -> Tuple[int, bytes]:
    """Retries network errors and 5xx. Returns (status, body) for everything else."""
    all_headers = {"User-Agent": USER_AGENT}
    all_headers.update(headers or {})
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        all_headers["Content-Type"] = "application/json"
    for attempt in range(1, retries + 1):
        request = urllib.request.Request(url, data=data, method=method, headers=all_headers)
        try:
            with urllib.request.urlopen(request, timeout=120) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as err:
            if err.code < 500 or attempt == retries:
                return err.code, err.read()
        except OSError as err:
            if attempt == retries:
                raise Fatal("network error on %s %s: %s" % (method, url, err))
        time.sleep(min(60, 5 * 2 ** attempt))
    raise Fatal("no response from %s %s" % (method, url))


def put_file(url: str, path: str, content_type: str, retries: int = 4) -> None:
    """PUT to a presigned R2 URL. The Content-Type must match the one the server signed."""
    size = os.path.getsize(path)
    for attempt in range(1, retries + 1):
        try:
            with open(path, "rb") as fh:
                request = urllib.request.Request(url, data=fh, method="PUT", headers={
                    "Content-Type": content_type, "Content-Length": str(size)})
                with urllib.request.urlopen(request, timeout=900) as resp:
                    if 200 <= resp.status < 300:
                        return
        except urllib.error.HTTPError as err:
            if err.code < 500 or attempt == retries:
                raise Fatal("upload of %s failed (%s): %s" % (path, err.code, err.read()[:300]))
        except OSError as err:
            if attempt == retries:
                raise Fatal("upload of %s failed: %s" % (path, err))
        time.sleep(min(60, 5 * 2 ** attempt))
    raise Fatal("upload of %s failed after %d attempts" % (path, retries))


class VoiidApi:
    def __init__(self, base: str, token: str):
        self.base = base.rstrip("/")
        self.token = token

    def call(self, method: str, path: str, body=None) -> Tuple[int, dict]:
        status, raw = http_request(method, self.base + path, body=body,
                                   headers={"Authorization": "Bearer " + self.token})
        try:
            data = json.loads(raw.decode("utf-8")) if raw else {}
        except ValueError:
            data = {"raw": raw[:300].decode("utf-8", "replace")}
        return status, data


# ── manifest and state ───────────────────────────────────────────────────────────

def load_manifest(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        manifest = json.load(fh)
    seen = set()
    for series in manifest["series"]:
        if series["id"] in seen:
            raise Fatal("duplicate series id in manifest: %s" % series["id"])
        seen.add(series["id"])
        for film in series["films"]:
            if film["expected_license"] not in ALLOWED_LICENSES:
                raise Fatal("%s: license %r isn't on the allowed list" % (film["film_title"], film["expected_license"]))
    return manifest


def is_publishable(series: dict) -> bool:
    return series.get("publish") is True and series.get("rating") in POSTABLE_RATINGS


def load_state(work: str) -> dict:
    path = os.path.join(work, "state.json")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    return {"episodes": {}}


def save_state(work: str, state: dict) -> None:
    write_json(os.path.join(work, "state.json"), state)


# ── fetching ─────────────────────────────────────────────────────────────────────

def commons_info(title: str) -> dict:
    params = urllib.parse.urlencode({
        "action": "query", "format": "json", "prop": "videoinfo", "titles": title,
        "viprop": "url|size|sha1|mime|extmetadata|derivatives",
        "viextmetadatafilter": "LicenseShortName|LicenseUrl|Artist|Credit|UsageTerms",
    })
    status, raw = http_request("GET", COMMONS_API + "?" + params)
    if status != 200:
        raise Fatal("Wikimedia Commons API returned %s for %s" % (status, title))
    page = next(iter(json.loads(raw.decode("utf-8"))["query"]["pages"].values()))
    if not page.get("videoinfo"):
        raise Fatal("file not found on Wikimedia Commons: %s" % title)
    info = page["videoinfo"][0]
    meta = {k: re.sub(r"<[^>]+>", "", str(v.get("value", ""))).strip()
            for k, v in info.get("extmetadata", {}).items()}
    hd = next((d for d in info.get("derivatives", []) if d.get("transcodekey") == "1080p.vp9.webm"), None)
    canonical = page.get("title", title)
    return {
        "commons_title": canonical,
        "page_url": "https://commons.wikimedia.org/wiki/" + urllib.parse.quote(canonical.replace(" ", "_"), safe=":/"),
        "license": meta.get("LicenseShortName"),
        "license_url": meta.get("LicenseUrl"),
        "artist": meta.get("Artist"),
        "commons_credit": meta.get("Credit"),
        "original_url": info.get("url"),
        "original_size": info.get("size"),
        "original_sha1": info.get("sha1"),
        "download_url": hd["src"] if hd else info.get("url"),
        "download_kind": "commons-1080p-transcode" if hd else "original",
        "extmetadata": info.get("extmetadata", {}),
    }


def download(url: str, dest: str, expected_size: Optional[int], expected_sha1: Optional[str]) -> None:
    if os.path.exists(dest):  # only ever renamed into place after verification
        return
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    part = dest + ".part"
    for attempt in range(1, 5):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(request, timeout=120) as resp, open(part, "wb") as out:
                for chunk in iter(lambda: resp.read(1 << 20), b""):
                    out.write(chunk)
            break
        except OSError as err:
            if attempt == 4:
                raise Fatal("download failed: %s (%s)" % (url, err))
            log("download retry %d: %s" % (attempt, err))
            time.sleep(15 * attempt)
    if expected_size and os.path.getsize(part) != expected_size:
        raise Fatal("downloaded size doesn't match Commons for %s" % url)
    if expected_sha1 and file_hash(part, "sha1") != expected_sha1:
        raise Fatal("downloaded SHA-1 doesn't match Commons for %s" % url)
    os.replace(part, dest)


# ── processing ───────────────────────────────────────────────────────────────────

def descriptor_line(series: dict) -> str:
    if series.get("descriptors"):
        return ", ".join(series["descriptors"])
    return POSTABLE_RATINGS.get(series.get("rating"), "Rating pending")


def build_caption(series: dict, number: int, total: int, film: dict, multi_film: bool) -> str:
    lines = ["%s · Episode %d of %d" % (series["title"], number, total)]
    if multi_film:
        lines.append(film["film_title"])
    lines += ["",
              "Rated %s · %s" % (series.get("rating") or "pending", descriptor_line(series)),
              "%s. Cut into episodes and made vertical." % film["credit"],
              "",
              "#VoiidSeries"]
    return "\n".join(lines)[:MAX_CAPTION_LEN]


def process_series(series: dict, manifest: dict, work: str, tools: Tuple[str, str],
                   font: str, state: dict) -> List[str]:
    """Fetch, verify, cut and format one series. Returns its episode ids in order."""
    ffmpeg, ffprobe = tools
    sid = series["id"]
    records_dir = os.path.join(work, "records", sid)
    os.makedirs(records_dir, exist_ok=True)
    multi_film = len(series["films"]) > 1

    planned = []  # (film, source path, start s, end s)
    for film in series["films"]:
        info = commons_info(film["commons_file"])
        if info["license"] != film["expected_license"]:
            log("SKIP %s / %s: Commons says %r, manifest expects %r"
                % (series["title"], film["film_title"], info["license"], film["expected_license"]))
            continue
        slug = slugify(film["film_title"])
        ext = os.path.splitext(urllib.parse.urlparse(info["download_url"]).path)[1] or ".webm"
        src = os.path.join(work, "downloads", sid, slug + ext)
        original = info["download_kind"] == "original"
        log("download %s / %s (%s)" % (series["title"], film["film_title"], info["download_kind"]))
        download(info["download_url"], src,
                 info["original_size"] if original else None,
                 info["original_sha1"] if original else None)

        status, page_html = http_request("GET", info["page_url"])
        if status == 200:
            with open(os.path.join(records_dir, slug + ".commons-page.html"), "wb") as fh:
                fh.write(page_html)

        meta = video.probe(ffprobe, src)
        cuts = video.plan_episodes(meta["duration"], video.scene_changes(ffmpeg, src))
        source_record = dict(info)
        source_record.update({
            "film_title": film["film_title"], "manifest_credit": film["credit"],
            "checked_at_utc": utc_now(), "downloaded_file": src,
            "downloaded_sha256": file_hash(src), "downloaded_bytes": os.path.getsize(src),
            "source_width": meta["width"], "source_height": meta["height"],
            "source_duration_s": meta["duration"], "episode_cuts_s": cuts,
        })
        write_json(os.path.join(records_dir, slug + ".source.json"), source_record)
        planned += [(film, src, start, end) for start, end in cuts]

    total = len(planned)
    episode_ids, episode_records = [], []
    for number, (film, src, start, end) in enumerate(planned, 1):
        eid = "%s-ep%02d" % (sid, number)
        episode_ids.append(eid)
        entry = state["episodes"].setdefault(eid, {})
        if entry.get("posted_at"):
            episode_records.append(entry.get("record", {}))
            continue

        caption = build_caption(series, number, total, film, multi_film)
        cut = [round(start, 3), round(end, 3)]
        files_ok = bool(entry.get("files")) and all(os.path.exists(p) for p in entry["files"].values())
        if not (files_ok and entry.get("cut") == cut and entry.get("caption") == caption):
            out_dir = os.path.join(work, "episodes", sid, "ep%02d" % number)
            title = "%s · Episode %d of %d" % (series["title"], number, total)
            if multi_film:
                title += "\n" + film["film_title"]
            rating_line = "Rated %s\n%s" % (series.get("rating") or "pending", descriptor_line(series))
            credit = "%s. Cut into episodes and made vertical." % film["credit"]

            log("render %s (%.1fs to %.1fs)" % (eid, start, end))
            master = video.render_episode(ffmpeg, src, start, end, out_dir, title, rating_line, credit, font)
            files = video.make_renditions(ffmpeg, master, out_dir)
            duration = video.probe(ffprobe, master)["duration"]
            files["thumb"] = video.make_thumb(ffmpeg, master, out_dir, duration)

            duration_ms = int(round(duration * 1000))
            if duration_ms > MAX_DURATION_MS:
                raise Fatal("%s is %d ms, over the server's %d ms limit" % (eid, duration_ms, MAX_DURATION_MS))
            for name in ("fhd", "hd", "sd"):
                if os.path.getsize(files[name]) > MAX_BYTE_SIZE:
                    raise Fatal("%s %s file is over 100 MB" % (eid, name))

            entry.update({
                "cut": cut, "caption": caption, "files": files, "duration_ms": duration_ms,
                "record": {
                    "episode_id": eid, "series": series["title"], "episode": number, "of": total,
                    "film_title": film["film_title"], "commons_file": film["commons_file"],
                    "license": film["expected_license"], "credit": credit,
                    "start_s": cut[0], "end_s": cut[1], "duration_ms": duration_ms,
                    "rating": series.get("rating"), "descriptors": series.get("descriptors", []),
                    "rated_by": manifest.get("rated_by"),
                    "edits": ["cut from the film",
                              "reformatted to 1080x1920 over a blurred copy of the frame",
                              "series title, rating card (first %d s) and credit added" % int(video.RATING_CARD_S),
                              "720p and 480p versions made"],
                    "files_sha256": {name: file_hash(path) for name, path in files.items()},
                    "rendered_at_utc": utc_now(),
                },
            })
            save_state(work, state)
        episode_records.append(entry["record"])

    write_json(os.path.join(records_dir, "episodes.json"), episode_records)
    return episode_ids


# ── posting ──────────────────────────────────────────────────────────────────────

def preflight_api(manifest: dict) -> VoiidApi:
    base = os.environ.get("VOIID_API_BASE", "").strip()
    token = os.environ.get("VOIID_TOKEN", "").strip()
    if not base or not token:
        raise Fatal("set VOIID_API_BASE (e.g. https://api-dev.voiid.app/v1) and VOIID_TOKEN, or use --dry-run")
    rated_by = str(manifest.get("rated_by", "")).strip()
    if not rated_by or rated_by.startswith(PLACEHOLDER_PREFIX):
        raise Fatal("put the name of the person who watched and rated the series in 'rated_by' in the manifest")

    claims = jwt_claims(token)
    if claims.get("client") == "web":
        raise Fatal("this is a web companion token, which can't post clips; use a phone session token")
    if claims.get("scope") != "session":
        log("WARNING: token isn't a device session token; the server may refuse it")

    api = VoiidApi(base, token)
    status, data = api.call("GET", "/creators/me")
    if status != 200:
        raise Fatal("token check failed (%s): %s" % (status, data))
    if not data.get("profile"):
        raise Fatal("the official account has no creator profile; create its handle in the app first")
    log("posting as @%s" % data["profile"].get("handle"))
    return api


def check_token_expiry(token: str, posts: int, interval_minutes: int) -> None:
    exp = jwt_claims(token).get("exp")
    needed = max(0, posts - 1) * interval_minutes * 60 + 3 * 3600  # slack for uploads and limit waits
    if exp and exp - time.time() < needed:
        raise Fatal("VOIID_TOKEN expires in %.1f h but posting needs about %.1f h; get a fresh token"
                    % ((exp - time.time()) / 3600, needed / 3600))


def wait_for_quota(api: VoiidApi) -> None:
    """Sleep while the account already has MAX_CLIPS_PER_DAY clips in the last 24 hours.

    /clips/mine hides deleted clips but the server's cap counts them, so a 429 on POST
    is still possible; post_episode raises QuotaHit for that case.
    """
    while True:
        status, data = api.call("GET", "/clips/mine?limit=60")
        if status != 200:
            raise Fatal("couldn't list the official account's clips (%s): %s" % (status, data))
        now = dt.datetime.now(dt.timezone.utc)
        day = dt.timedelta(hours=24)
        recent = sorted(t for t in (parse_time(c["created_at"]) for c in data.get("clips", [])) if now - t < day)
        if len(recent) < MAX_CLIPS_PER_DAY:
            return
        frees_at = recent[len(recent) - MAX_CLIPS_PER_DAY] + day
        wait_s = max(300.0, (frees_at - now).total_seconds() + 120)
        log("%d clips posted in the last 24 h; waiting %d min" % (len(recent), wait_s // 60))
        time.sleep(wait_s)


def post_episode(api: VoiidApi, eid: str, entry: dict, work: str, state: dict, rated_by: str) -> None:
    if not entry.get("clip_id"):
        entry["clip_id"] = str(uuid.uuid4())  # client-generated, so a retried POST can't double-post
        save_state(work, state)
    files = entry["files"]

    status, pre = api.call("POST", "/clips/presign-upload", {"mime": "video/mp4"})
    if status != 200:
        raise Fatal("presign-upload failed (%s): %s" % (status, pre))
    log("upload %s" % eid)
    put_file(pre["upload_url"], files["fhd"], "video/mp4")
    for name in ("fhd", "hd", "sd"):
        put_file(pre["renditions"][name]["upload_url"], files[name], "video/mp4")
    put_file(pre["thumb_upload_url"], files["thumb"], "image/jpeg")

    body = {
        "clip_id": entry["clip_id"], "r2_key": pre["key"], "thumb_r2_key": pre["thumb_key"],
        "caption": entry["caption"], "duration_ms": entry["duration_ms"],
        "width": 1080, "height": 1920, "byte_size": os.path.getsize(files["fhd"]),
        "cover_source": "frame",
    }
    for name in ("sd", "hd", "fhd"):
        body["r2_key_" + name] = pre["renditions"][name]["key"]
        body["byte_size_" + name] = os.path.getsize(files[name])

    status, data = api.call("POST", "/clips", body)
    if status == 429:
        raise QuotaHit(str(data))
    if status == 428:
        raise Fatal("the official account has no creator profile; create its handle in the app")
    if status not in (200, 409):  # 409: this clip_id already landed on an earlier attempt
        raise Fatal("POST /clips failed for %s (%s): %s" % (eid, status, data))

    entry["posted_at"] = utc_now()
    save_state(work, state)
    posts_csv = os.path.join(work, "records", "posts.csv")
    new_file = not os.path.exists(posts_csv)
    with open(posts_csv, "a", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        if new_file:
            writer.writerow(["posted_at_utc", "episode_id", "clip_id", "rated_by", "caption_first_line"])
        writer.writerow([entry["posted_at"], eid, entry["clip_id"], rated_by, entry["caption"].split("\n")[0]])
    log("posted %s as clip %s" % (eid, entry["clip_id"]))


# ── main ─────────────────────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    here = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser(description="Fetch, cut, format and post Voiid series 1-5.")
    parser.add_argument("--dry-run", action="store_true", help="do everything except posting")
    parser.add_argument("--only", default="", help="comma-separated series ids from the manifest")
    parser.add_argument("--interval-minutes", type=int, default=50, help="minutes between posts (default 50)")
    parser.add_argument("--work-dir", default="~/voiid-series-1-5", help="downloads, episodes, records, logs")
    parser.add_argument("--include-held", action="store_true",
                        help="also format held series for review (they are never posted)")
    parser.add_argument("--manifest", default=os.path.join(here, "series_1_5_manifest.json"))
    return parser.parse_args()


def run_pipeline(args: argparse.Namespace) -> None:
    global _log_path
    work = os.path.abspath(os.path.expanduser(args.work_dir))
    if not SAFE_WORK_DIR.match(work):
        raise Fatal("--work-dir may only contain letters, digits and . _ / ~ - (no spaces): %s" % work)
    os.makedirs(os.path.join(work, "records"), exist_ok=True)
    _log_path = os.path.join(work, "pipeline.log")
    log("start%s; work dir %s" % (" (dry run)" if args.dry_run else "", work))

    manifest = load_manifest(args.manifest)
    tools = video.find_tools()
    font = video.find_font()

    wanted = {s.strip() for s in args.only.split(",") if s.strip()}
    unknown = wanted - {s["id"] for s in manifest["series"]}
    if unknown:
        raise Fatal("unknown series id(s): %s" % ", ".join(sorted(unknown)))
    selected = [s for s in manifest["series"] if not wanted or s["id"] in wanted]
    for series in selected:
        if not is_publishable(series):
            log("HOLD %s: %s" % (series["title"],
                                 series.get("hold_reason") or "rating %r can't be posted" % series.get("rating")))

    api = None if args.dry_run else preflight_api(manifest)
    state = load_state(work)

    queue = []
    for series in selected:
        publishable = is_publishable(series)
        if not publishable and not args.include_held:
            continue
        ids = process_series(series, manifest, work, tools, font, state)
        if publishable:
            queue += [eid for eid in ids if not state["episodes"][eid].get("posted_at")]

    if api is None:
        log("dry run done: %d episode(s) ready to post, nothing posted" % len(queue))
        return

    check_token_expiry(api.token, len(queue), args.interval_minutes)
    for index, eid in enumerate(queue):
        if index and args.interval_minutes > 0:
            log("waiting %d min before the next post" % args.interval_minutes)
            time.sleep(args.interval_minutes * 60)
        while True:
            wait_for_quota(api)
            try:
                post_episode(api, eid, state["episodes"][eid], work, state, manifest["rated_by"])
                break
            except QuotaHit:
                log("server says the daily clip limit is reached; waiting 60 min")
                time.sleep(3600)
    log("done: %d episode(s) posted" % len(queue))


def main() -> int:
    args = parse_args()
    try:
        run_pipeline(args)
    except (Fatal, video.VideoError) as err:
        log("STOPPED: %s" % err)
        return 1
    except KeyboardInterrupt:
        log("interrupted; progress is saved, run again to continue")
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
