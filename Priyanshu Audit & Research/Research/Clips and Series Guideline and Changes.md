# Clips and Series: Guideline and Changes

> **Researched:** 15 Sep 2026
> **Status:** Research notes, not legal advice. Have a lawyer review before launch.
> **Related:** [Global – Safest Baseline](Global%20-%20Safest%20Baseline.md) · [India](India.md) · [US](US.md) · [EU & UK](EU%20%26%20UK.md)

---

## 1. Decisions

- **No fake users.** The official Voiid account posts every seeded series and clip.
- **Worldwide launch.** Every source must be usable in every country.
- **Seed content:** 15 mini series and 100 clips.
- **Children:** accounts only when linked to a verified parent. Full design in [Global – Safest Baseline](Global%20-%20Safest%20Baseline.md).

## 2. What the app does today

Checked in the code on 15 Sep 2026.

| Area | Today | Where |
|---|---|---|
| Clips player | Portrait, vertical swipe. Videos are fitted, not cropped, so a 16:9 video shows as a thin strip | [ClipFullscreenView.kt](../../apps/android/app/src/main/java/com/voiid/app/main/clips/ClipFullscreenView.kt) |
| Episodes | "2-min episode format" planned, not built | [CHECKLIST.md](../../docs/CHECKLIST.md) |
| Signup | Permissions → phone → OTP (Firebase) → photo, name, username → optional email and bio | [OnboardingFlow.swift](../../apps/ios/Voiid/Voiid/Onboarding/OnboardingFlow.swift), [SignupScreen.swift](../../apps/ios/Voiid/Voiid/Onboarding/SignupScreen.swift) |
| Age | Not collected anywhere | — |
| Accounts | One account per phone number (`phone_number ... unique`) | [001_users.sql](../../database/migrations/001_users.sql), [auth.ts](../../backend/api/src/routes/auth.ts) |
| New devices | A logged-in device scans a QR code to approve a new device | [linking.ts](../../backend/api/src/routes/linking.ts) |
| Location sharing | Exists in chats | [LocationDetailView.kt](../../apps/android/app/src/main/java/com/voiid/app/main/LocationDetailView.kt) |
| Shopping | Planned (Phase 8, Razorpay) | [PHASE_PLAN.md](../../docs/PHASE_PLAN.md) |

---

## 3. The 15 series

### Cut from free films

Voiid's server rejects clips longer than 90 seconds (`MAX_DURATION_MS` in [clips.ts](../../backend/api/src/routes/clips.ts)). So each film is split into episodes of about 55–88 seconds at scene changes. [series_1_5_pipeline.py](series_1_5_pipeline.py) does this automatically; see [00 - Start Here](00%20-%20Start%20Here.md).

| # | Series | Source | License | Episodes (approx.) | Rating (confirm after watching) |
|---|---|---|---|---|---|
| 1 | Caminandes | Blender Foundation, via Wikimedia Commons | Ep 1 & 3: CC BY 3.0 · Ep 2: CC BY-SA 3.0 | ~6 (films of 1.5, 2.4 and 2.5 min) | U |
| 2 | Pepper & Carrot | Morevna Project, via Wikimedia Commons | CC BY 4.0 | ~6 from Episode 6 (7.6 min); Episodes 3–5 manual | U |
| 3 | Big Buck Bunny | Blender Foundation, via Wikimedia Commons | CC BY 3.0 | ~8 (10.6 min) | U |
| 4 | Sintel | Blender Foundation, via Wikimedia Commons | CC BY 3.0 | ~11 (14.8 min) | U/A 7+ or U/A 13+ (fights, a death) |
| 5 | Blender Shorts: Coffee Run, Wing It | Blender Studio, via Wikimedia Commons | CC BY 4.0 | ~6 (films of 3.1 and 4.0 min) | U |

- Caminandes Ep 2 is CC BY-SA, so our edited version must also be shared under CC BY-SA.
- If Sintel rates U/A 13+, leave it out until parental locks exist. The script holds Sintel until its rating is set.
- **Pepper & Carrot Episodes 3–5:** no official download found. The archive.org copies were uploaded by a third party and labelled CC BY-SA 4.0, which contradicts Morevna's CC BY 4.0. Get the files from Morevna Project directly and confirm the license first.
- **Daily limit:** one account can post at most 30 clips per 24 hours (`MAX_CLIPS_PER_DAY`), so posting ~26 episodes takes about a day.
- **Creator profile:** posting needs one (a handle) on the official account.

### Made by Voiid

Our own script, voice and art. The footage or story itself is free to use.

| # | Series | Material | License | Rating (guess) |
|---|---|---|---|---|
| 6 | Space Facts | ESA/Hubble and ESA/Webb footage | CC BY 4.0 (their music is not included) | U |
| 7 | Ocean Mysteries | NOAA Fisheries B-roll packages only (not their narrated videos) | Public domain in the US; credit NOAA Fisheries | U |
| 8 | Wild Planet | Free Nature Stock | CC0 | U |
| 9 | Panchatantra | Ancient tales | Public domain | U |
| 10 | Akbar–Birbal | Folk tales | Public domain | U |
| 11 | Tenali Raman | Folk tales | Public domain | U |
| 12 | Vikram–Betaal | 11th-century story collection; each story ends in a riddle | Public domain | U/A 7+ |
| 13 | Jataka Tales | Ancient Buddhist tales | Public domain | U |
| 14 | Aesop's Fables | Ancient Greek fables | Public domain | U |
| 15 | Grimm Fairy Tales | Original 1812–1857 stories | Public domain | U/A 7+ |

For series 9–15:
- Write our own retelling. Don't copy Disney, Amar Chitra Katha, Tinkle, TV shows or modern translations.
- Use our own series titles and visual style.
- Take care with religious figures and communities. India's IT Rules ask publishers to be careful with religious and racial content.

### Dropped

| Item | Why |
|---|---|
| Tears of Steel | Likely U/A 13+, which needs parental locks |
| Sprite Fright | Horror; license page couldn't be reached |
| Cosmos Laundromat | Opens with a suicide attempt; uses the f-word |
| Spring | Only its asset files are confirmed CC BY 4.0, not the film itself |
| Premchand stories | Stories published in 1931 or later are still copyrighted in the US |
| Silent comedies (Chaplin etc.) | Still copyrighted in Europe |
| NASA as the main space source | Only confirmed public domain inside the US; the US government says it can claim copyright abroad |

---

## 4. The 100 clips

| Count | Type | How |
|---|---|---|
| 40 | Knowledge, 30–60s | ESA, Free Nature Stock or NOAA footage with our own script, voice and captions |
| 30 | Series teasers | Best 20–40s moments of series 1–5; caption points to the full series |
| 30 | Funny | Made by the team, or paid creators with a written agreement giving Voiid rights |

Get written consent from everyone who appears on camera.

---

## 5. License rules

**Accept**
- CC0
- CC BY (any version)
- CC BY-SA, as long as our edited version is shared under CC BY-SA too
- Stories that are public domain everywhere (ancient and folk tales)
- A written agreement that gives Voiid the rights

**Reject**
- CC NonCommercial (NC) or NoDerivatives (ND)
- Stock sites that ban reposting clips as they are: Pexels, Pixabay, Mixkit, Coverr, Storyblocks. Pexels' terms say "resizing or cropping the Content remains Standalone use."
- Anything taken from YouTube, Instagram, TikTok, Vimeo, films, TV, sports or news
- Modern retellings, translations or artwork of old stories
- Logos: Blender and film logos, ESA/Hubble and ESA/Webb logos, NASA insignia

## 6. Credits

Show credits in two places: on screen and in the caption. ESA/Webb asks for credits to be visible on the video itself.

Format: `<Title> — <Creator>, <License>. <What we changed>.`

Examples:
- `Coffee Run — Blender Studio, CC BY 4.0. Cut into episodes and made vertical.`
- `Llama Drama — Blender Foundation (Pablo Vazquez, Beorn Leonard, Francesco Siddi; music and sound by Jan Morgenstern), CC BY 3.0. Made vertical.`
- `Footage: ESA/Hubble, CC BY 4.0. Script and voice: Voiid.`
- `Music: <track> by Kevin MacLeod (incompetech.com), CC BY.`

## 7. Audio

- **Series 1–5:** keep the original dialogue, music and sound. The film's license covers them.
- **Series 6–15 and clips:**
  - **Voices:** our team, or AI voices on a paid plan that allows commercial use
  - **Background music:** Incompetech (CC BY, credit Kevin MacLeod), or an AI music tool on a paid commercial plan
  - **Sound effects:** Freesound, only sounds marked CC0 or CC BY
- **Never:** film or trending songs, or music from ESA, NASA or any other source site

## 8. Vertical format

- Export at 1080×1920.
- Place the horizontal film in the middle, with a blurred, enlarged copy of the same frame behind it.
- Title at the top, credit at the bottom.

---

## 9. AI-made content

- Show a **"Made with AI"** tag in the player and caption for every AI-made episode or clip.
- **EU AI Act, Article 50 (since 2 Aug 2026):** AI-generated or altered content must be disclosed. For fiction and art, a light disclosure that doesn't spoil viewing is allowed.
- **India IT Rules (10 Feb 2026 amendment):** the label rules cover AI content that looks real. Cartoons likely fall outside, but we label anyway.
- Use paid plans that allow commercial use. No real people's faces or voices, and no famous characters.
- Record the tool, plan and date for each AI-made file.

## 10. Ratings

India's IT Rules treat content that Voiid itself owns or licenses and offers on demand as "online curated content", with Voiid as the publisher.

- **Who rates:** Voiid rates its own content. CBFC certification isn't needed.
- **Categories:** U, U/A 7+, U/A 13+, U/A 16+, A.
- **Content descriptors:** themes and messages, violence, nudity, sex, language, drugs and substance abuse, horror.
- **Where to show:** rating and descriptors before each episode starts, on the series page and in promos.
- **Parental locks:** required for U/A 13+ and above.
- **Age verification:** required for A.
- **Our rule:** keep all official content at U or U/A 7+. Never post anything rated A.
- **Keep a record:** who rated it, when, the descriptors and the reason.
- **User posts:** don't need ratings. For those, Voiid is only the platform.

The same ratings drive age filtering worldwide. See [Global – Safest Baseline](Global%20-%20Safest%20Baseline.md).

## 11. Complaints and takedowns

| Rule | What it requires | Since |
|---|---|---|
| India IT Rules: every platform where users post | Grievance Officer's name and contact on the home screen or one screen away. Acknowledge complaints within 24 hours, resolve within 7 days. Certain removal requests: 36 hours. Nude or sexual images of a person: 2 hours | Now |
| India IT Rules: publisher of Voiid's own content | Grievance Officer based in India; contact details shown | Now |
| US TAKE IT DOWN Act | Clear way to report non-consensual intimate images; remove within 48 hours, plus known copies | 19 May 2026 |
| US DMCA | Register a DMCA agent to keep safe harbor for user uploads (see [US](US.md)) | Now |
| EU Digital Services Act | Reporting ("notice and action"); explain removal decisions to users | Now |
| Brazil Digital ECA | Remove flagged criminal content immediately once identified, notify the authorities, keep the data | 2026 |

- A founder or teammate can be the Grievance Officer. It doesn't need a new hire.
- Put a Report button on every clip, profile and message.
- Put a Complaints screen one tap from the home screen.

## 12. Records to keep

For every file:
- Source link, creator, exact license and version
- Dated screenshot or PDF of the license page
- File hash (SHA-256) and download date
- Credit line and what we changed
- Rating, descriptors, who rated it and why
- AI tool, plan and date (if AI-made)
- Consent forms for people on camera; creator agreements

Keep records for at least 3 years, including for deleted videos.

## 13. Deleting seeded content later

- We can delete it anytime, but we don't have to: the licenses don't expire.
- Deleting doesn't undo a problem that existed while it was live. Claims can usually be filed for up to 3 years.
- Removing Voiid's content doesn't remove the Grievance Officer duty, because users still post.

---

## 14. Signup and account changes

Full design and reasons: [Global – Safest Baseline](Global%20-%20Safest%20Baseline.md).

1. Ask everyone for birth month and year at signup, before the phone step. No default value, and no going back to change it.
2. Read Apple's and Google's age signals where available.
3. Under 13: blocked at launch.
4. 13–17: the account works only after a parent approves it on their own Voiid device, and the parent's age is checked once.
5. Protections for minors are on by default: private profile, no ads, location off, non-personalized feed, and more.
6. A Family Center for parents.

## 15. Engineering changes

### Database and backend
- [ ] `users`: add `birth_month`, `birth_year`, `age_band`, `account_type` (adult / teen / child), `country_code`, `age_signal_source`, `age_verified_at`
- [ ] Make `phone_number` optional for parent-linked accounts (still unique when set)
- [ ] New table `guardian_links`: child, parent, status, controls, created and revoked dates
- [ ] New table `consent_records`: parent, child, notice version, method, date, device
- [ ] New table `content_records`: every field from section 12
- [ ] Clips and series: add `rating`, `descriptors`, `is_ai_generated`, `credit_line`, `license`, `source_url`, `is_official`
- [ ] Endpoints to request, approve and revoke a parent link (reuse the QR approval pattern in [linking.ts](../../backend/api/src/routes/linking.ts))
- [ ] Parent endpoints to view, export and delete a child's data
- [ ] Enforce age rules on the server, not only in the app: rating filter by age band, feature limits by account type
- [ ] Complaints endpoint plus an admin queue with timers (2h / 24h / 36h / 48h / 7 days)

### iOS and Android (keep both in step)
- [ ] New onboarding steps: birth date, "ask a parent", waiting for approval ([OnboardingFlow.swift](../../apps/ios/Voiid/Voiid/Onboarding/OnboardingFlow.swift), [OnboardingFlow.kt](../../apps/android/app/src/main/java/com/voiid/app/onboarding/OnboardingFlow.kt))
- [ ] Family Center in Settings
- [ ] Rating badge and descriptors before each episode
- [ ] "Made with AI" tag and credit line in the player
- [ ] Report button on clips, profiles and messages; Complaints screen one tap from home
- [ ] Apple Declared Age Range API and Google Play Age Signals API
- [ ] Limits for minors: location sharing, being found by number or username, public posting, payments, public communities, night-time notifications

### Admin web
- [ ] Upload form that won't save without license, credit, rating and AI fields
- [ ] Complaints queue with timers
- [ ] Consent records view

---

## 16. Key dates

| Date | What | Where |
|---|---|---|
| 25 Jul 2025 | Protection of Children Codes in force | UK |
| 10 Dec 2025 | Under-16 minimum age for age-restricted social media (messaging apps exempt) | Australia |
| 10 Feb 2026 | IT Rules amendment: AI content labels | India |
| Mar 2026 | Digital ECA in effect | Brazil |
| 22 Apr 2026 | Amended COPPA Rule compliance deadline | US |
| 19 May 2026 | TAKE IT DOWN Act removal process | US |
| 2 Aug 2026 | AI Act Article 50 disclosure | EU |
| Nov 2026 | Digital ECA sanctions begin; compliance checks from Jan 2027 | Brazil |
| 1 Jan 2027 | California AB 1043 age signals; Alabama app store law; California SB 976 age verification | US |
| 6 May 2027 | Utah app store law | US |
| 13 May 2027 | DPDP children's data rules | India |
| 1 Jul 2027 | Louisiana app store law; AB 1043 deadline for existing users | US |

## 17. Before launch

- [ ] License proof and record for every file
- [ ] Credits on screen and in captions
- [ ] No stock-site or copyrighted music
- [ ] Every episode watched and rated; all at U or U/A 7+
- [ ] Rating badge before each episode
- [ ] "Made with AI" tag on AI-made content
- [ ] Grievance Officer named; contact one tap from home
- [ ] Report button everywhere; takedown queue with timers
- [ ] DMCA agent registered
- [ ] Birth date screen at signup
- [ ] Parent approval flow for under 18
- [ ] Protections for minors on by default
- [ ] Lawyer review covering India, US, EU/UK, Brazil and Australia

## 18. Questions for the lawyer

1. Does Clips make Voiid "social media" under Florida HB 3 and Australia's minimum-age law, and an "online platform" under the EU DSA?
2. Does a DigiLocker age token for the parent, plus approval on the parent's device, satisfy DPDP Rule 10?
3. If we add under-13 accounts, which COPPA consent method should we use?
4. Beyond ratings and a Grievance Officer, what else does India require from Voiid as a publisher of curated content? (Not researched here.)
5. Is NOAA footage acceptable outside the US?
6. What ratings should Sintel and Vikram–Betaal get?
7. Do we need an EU GDPR representative, an EU DSA legal representative and a UK representative?

---

## Sources

**Content licenses**
- [Pexels Terms of Service](https://www.pexels.com/terms-of-service/) · [Pixabay License Summary](https://pixabay.com/service/license-summary/) · [Coverr License](https://coverr.co/license)
- [Free Nature Stock License](https://freenaturestock.com/license/)
- [Caminandes 1 (Commons)](https://commons.wikimedia.org/wiki/File:Caminandes-_Llama_Drama_-_Short_Movie.ogv) · [Caminandes 2 (Commons)](https://commons.wikimedia.org/wiki/File:Caminandes_-_Gran_Dillama_-_Blender_Foundation%27s_new_Open_Movie.webm) · [Caminandes 3 (Commons)](https://commons.wikimedia.org/wiki/File:Caminandes_3_-_Llamigos_-_Blender_Animated_Short.webm)
- [Pepper & Carrot Motion Comic](https://morevnaproject.org/pepper-and-carrot/)
- [Big Buck Bunny](https://peach.blender.org/about/) · [Sintel](https://durian.blender.org/about/) · [Tears of Steel](https://mango.blender.org/about/)
- [Coffee Run licensing](https://studio.blender.org/films/coffee-run/pages/licensing/) · [Wing It! licensing](https://studio.blender.org/films/wing-it/pages/licensing/)
- [ESA/Hubble copyright](https://esahubble.org/copyright/) · [ESA/Webb copyright](https://esawebb.org/copyright/)
- [NOAA Fisheries videos](https://videos.fisheries.noaa.gov/) · [NASA media guidelines](https://www.nasa.gov/nasa-brand-center/images-and-media/)
- [US government works abroad (Wikipedia)](https://en.wikipedia.org/wiki/Copyright_status_of_works_by_the_federal_government_of_the_United_States) · [Cornell public domain chart](https://guides.library.cornell.edu/copyright/publicdomain)
- [Kevin MacLeod (Wikipedia)](https://en.wikipedia.org/wiki/Kevin_MacLeod)

**Rules**
- [India IT Rules, updated 10 Feb 2026 (MeitY)](https://www.meity.gov.in/static/uploads/2026/02/550681ab908f8afb135b0ad42816a1c9.pdf)
- [EU AI Act Article 50](https://artificialintelligenceact.eu/article/50/)
- Age and consent sources are listed in each country file.
