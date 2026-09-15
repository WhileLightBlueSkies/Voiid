# Start Here

> **Updated:** 15 Sep 2026
> **Status:** Research notes, not legal advice.

---

## 1. What's in this folder

| File | What it contains | Read it |
|---|---|---|
| **00 - Start Here.md** | This index, the guide to the series 1–5 script, and the to-do list for series 6–15 | First |
| [Clips and Series Guideline and Changes.md](Clips%20and%20Series%20Guideline%20and%20Changes.md) | The full content plan: 15 series, 100 clips, license, credit, music and AI rules, ratings, complaints and takedowns, records, signup changes, engineering changes, deadlines, pre-launch checklist, questions for the lawyer | Before making or posting any content |
| [Global - Safest Baseline.md](Global%20-%20Safest%20Baseline.md) | One worldwide rule set for age, children and parent consent. Review of the child-account idea, the recommended flow, defaults for minors, Family Center | Before building signup or child accounts |
| [India.md](India.md) | DPDP (children's data, checking the parent via DigiLocker) and IT Rules (ratings, parental locks, grievance timelines, AI labels) | India launch |
| [US.md](US.md) | COPPA, TAKE IT DOWN Act, DMCA, state laws (Florida, Texas, California, New York…), app store age signals | US launch |
| [EU & UK.md](EU%20%26%20UK.md) | GDPR consent ages by country, DSA minors rules, AI Act labels; UK Children's Code and Online Safety Act | Europe and UK launch |
| [series_1_5_pipeline.py](series_1_5_pipeline.py) | Script that fetches, cuts, formats and posts series 1–5 | Before posting series 1–5 |
| [series_1_5_video.py](series_1_5_video.py) | Video helper the script uses | Only if changing the video look |
| [series_1_5_manifest.json](series_1_5_manifest.json) | Script settings: films, licenses, credits, ratings, what's on hold | Before the first run |
| `../Audit/` | Empty for now | — |

---

## 2. The series 1–5 script

### What it does

1. **Checks setup:** ffmpeg-full, a font, the manifest, the API token and its expiry, and that the official account has a creator profile.
2. **Checks licenses:** asks Wikimedia Commons for each film's license. If it doesn't match the manifest, that film is skipped.
3. **Downloads** the 1080p version (or the original if there isn't one) and saves a copy of the Commons file page as license proof.
4. **Cuts episodes** of 55–88 seconds at scene changes. The server rejects clips over 90 seconds.
5. **Formats each episode** at 1080×1920:
   - the film in the middle, over a blurred copy of itself
   - series title and episode number at the top
   - rating card for the first 4 seconds
   - credit line at the bottom
6. **Makes 720p and 480p versions** and a cover image, the same ladder the apps use.
7. **Writes records:** source link, license, artist, file hashes, cut times, rating, who rated it, edits made.
8. **Posts** each episode from the official account: uploads to storage, then creates the clip with a caption (title, rating, credit, #VoiidSeries).
9. **Paces itself:** waits between posts (default 50 minutes) and pauses when the account hits 30 clips in 24 hours.
10. **Remembers progress** in `state.json`, so a rerun picks up where it stopped and never posts twice.

### What it won't do

- **Post Sintel** until someone watches it, sets its rating in the manifest and sets `publish` to `true`.
- **Post anything rated above U/A 7+.**
- **Post while `rated_by` in the manifest is still the placeholder.**
- **Fetch Pepper & Carrot Episodes 3–5** (no official download).
- **Make teaser clips or series 6–15.**
- **Download from YouTube** or any source without machine-readable license data.

### One-time setup

1. Install ffmpeg with text support: `brew install ffmpeg-full`
2. Log in to the official Voiid account on a phone and create its creator profile (handle).
3. **Get a session token** for the official account and use it as `VOIID_TOKEN`:
   - It must come from a phone login. Web companion tokens can't post clips.
   - Session tokens last 30 days by default. The script refuses to start if the token would expire mid-run.
   - Don't register the script as a new iOS or Android device for that account. Voiid allows one active device per platform, so that would sign the official account's phone out.
4. Watch series 1, 2, 3 and 5 (and Sintel if you plan to post it), confirm the ratings in the manifest, and put your name in `rated_by`.

### Run

```bash
cd "Priyanshu Audit & Research/Research"

# 1. Everything except posting: download, cut, format, records. No token needed.
python3 series_1_5_pipeline.py --dry-run

# 2. Full run (posts). Point it at dev first and check the clips in the app.
export VOIID_API_BASE="https://api-dev.voiid.app/v1"
export VOIID_TOKEN="<official account session token>"
caffeinate -i python3 series_1_5_pipeline.py
```

`caffeinate -i` keeps the Mac awake; a full run takes about a day.

| Option | What it does |
|---|---|
| `--dry-run` | Everything except posting |
| `--only caminandes,big-buck-bunny` | Only these series (IDs from the manifest) |
| `--interval-minutes 50` | Minutes to wait between posts (default 50) |
| `--work-dir ~/voiid-series-1-5` | Where downloads, episodes, records and logs go. No spaces allowed in the path |
| `--include-held` | Also formats held series (e.g. Sintel) so they can be reviewed. They're still not posted |
| `--manifest PATH` | Use a different manifest file |

### Output (in the work folder)

| Path | Contents |
|---|---|
| `downloads/` | Source files |
| `episodes/<series>/epNN/` | `fhd.mp4`, `hd.mp4`, `sd.mp4`, `thumb.jpg` |
| `records/<series>/` | License data, a copy of the Commons page, `episodes.json` |
| `records/posts.csv` | Every posted clip with its ID |
| `state.json` | Progress |
| `pipeline.log` | Full log |

Copy `records/` to shared storage after each run, and keep it for at least 3 years.

### Expected episodes

| Series | Episodes (approx.) | Posted? |
|---|---|---|
| 1 Caminandes | 6 | Yes |
| 2 Pepper & Carrot (Episode 6 only) | 6 | Yes |
| 3 Big Buck Bunny | 8 | Yes |
| 4 Sintel | 11 | Held until rated |
| 5 Blender Shorts | 6 | Yes |

That's about 26 posts, roughly 22 hours at the default interval.

### Before the first real run

- [ ] Dry run finished; a few episodes watched from `episodes/` (text readable, credit visible, audio fine)
- [ ] `rated_by` set in the manifest
- [ ] Token comes from a phone session and won't expire during the run
- [ ] Official account has a creator profile
- [ ] Tested against the dev API and checked in the app

### Known gaps

- **No series grouping yet:** the app has no series or episode support, so each episode posts as a normal clip with "Series · Episode N of M" in the caption.
- **No database fields yet** for rating, AI flag, credit or license (see section 15 of the main doc). The script puts them in the video, the caption and the records.
- **Not run yet:** the script has only been syntax-checked.

---

## 3. Series 6–15: what needs to be done

### Steps for every episode

1. **Script:** 45–85 seconds of narration (the server limit is 90 seconds). Our own words. Check facts against two sources for series 6–8.
2. **Visuals:** 1080×1920 portrait. Footage for 6–8; our own or AI-made art for 9–15.
3. **Voice:** a team member, or an AI voice on a paid plan that allows commercial use.
4. **Music:** Incompetech (credit Kevin MacLeod) or AI music on a paid commercial plan. Sound effects only if marked CC0 or CC BY on Freesound.
5. **Edit:** title at the top, credit at the bottom, captions.
6. **Rating:** rating card at the start with content descriptors. Aim for U or U/A 7+.
7. **AI tag:** "Made with AI" if any AI was used.
8. **Records:** sources, licenses, AI tool, plan and date, voice and music credits, rating and who rated it.
9. **Watch and approve** before posting.

### Per series

| # | Series | Material and where to get it | Credit line | Take care | Episodes to start |
|---|---|---|---|---|---|
| 6 | Space Facts | ESA/Hubble and ESA/Webb videos (esahubble.org, esawebb.org), CC BY 4.0. Mute their music | Exact credit from each video page, e.g. "ESA/Hubble", on screen | No ESA logos; skip videos credited to third parties | 10 |
| 7 | Ocean Mysteries | NOAA Fisheries B-roll packages (videos.fisheries.noaa.gov), public domain in the US | "Footage: NOAA Fisheries" | B-roll packages only, not narrated videos; ask the lawyer about use outside the US | 8 |
| 8 | Wild Planet | Free Nature Stock (freenaturestock.com), CC0 | "Footage: Free Nature Stock" (optional, but add it) | Skip clips with people or brands | 10 |
| 9 | Panchatantra | Ancient tales | "Based on the Panchatantra (public domain). Retold by Voiid." | Don't copy Amar Chitra Katha, Tinkle or modern translations | 10 |
| 10 | Akbar–Birbal | Folk tales | "Based on traditional Akbar–Birbal tales. Retold by Voiid." | Respectful portrayal of historical and religious figures | 10 |
| 11 | Tenali Raman | Folk tales | "Based on traditional Tenali Raman tales. Retold by Voiid." | Don't reuse any TV show's title or look | 10 |
| 12 | Vikram–Betaal | The 25 Vetala tales; each ends in a riddle | "Based on the Vetala tales (public domain). Retold by Voiid." | Ghost theme: keep it mild enough for U/A 7+ | 10 |
| 13 | Jataka Tales | Ancient Buddhist tales | "Based on the Jataka tales (public domain). Retold by Voiid." | Respectful religious portrayal | 10 |
| 14 | Aesop's Fables | Ancient Greek fables | "Based on Aesop's Fables (public domain). Retold by Voiid." | Old translations only as reference; write our own | 10 |
| 15 | Grimm Fairy Tales | Original 1812–1857 stories | "Based on the Brothers Grimm tales (public domain). Retold by Voiid." | Don't copy Disney versions; tone down violence for U/A 7+ | 10 |

### Owners and status

| # | Series | Owner | Scripts | Visuals | Voice | Music | Rated | Posted |
|---|---|---|---|---|---|---|---|---|
| 6 | Space Facts | | | | | | | |
| 7 | Ocean Mysteries | | | | | | | |
| 8 | Wild Planet | | | | | | | |
| 9 | Panchatantra | | | | | | | |
| 10 | Akbar–Birbal | | | | | | | |
| 11 | Tenali Raman | | | | | | | |
| 12 | Vikram–Betaal | | | | | | | |
| 13 | Jataka Tales | | | | | | | |
| 14 | Aesop's Fables | | | | | | | |
| 15 | Grimm Fairy Tales | | | | | | | |

---

## 4. Also still to do

- **100 clips:** see section 4 of [Clips and Series Guideline and Changes.md](Clips%20and%20Series%20Guideline%20and%20Changes.md)
- **Pepper & Carrot Episodes 3–5:** get official files from Morevna Project and confirm the license
- **Signup and age changes:** see [Global - Safest Baseline.md](Global%20-%20Safest%20Baseline.md)
- **Grievance Officer and Complaints screen**
- **Lawyer review:** see section 18 of the main doc
