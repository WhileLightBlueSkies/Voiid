import type { Metadata } from 'next';
import { Hero } from '../../components/Hero';
import { Section, Split } from '../../components/Section';
import { CTA } from '../../components/CTA';
import { Button, ButtonRow } from '../../components/Button';
import { E2EEBadge } from '../../components/E2EEBadge';
import { Callout } from '../../components/Callout';
import { Glyph } from '../../components/Glyph';
import {
  PhoneMockup,
  PhoneAppBar,
  ChatBubble,
  PhoneAvatar,
} from '../../components/PhoneMockup';
import styles from './page.module.css';

export const metadata: Metadata = {
  title: 'Map',
  description:
    'Voiid’s Map opens ghosted: you appear to no one until you name individual people. ' +
    'Positions are end-to-end encrypted, ghosting mints a fresh key, and our servers ' +
    'store that a share exists — never where you are.',
};

/*
 * SOURCES FOR EVERY CLAIM ON THIS PAGE. Checked, not remembered:
 *
 *   docs/LOCATION.md                                   the spec, §§1-11
 *   database/migrations/018_location_shares.sql        the entire server-side footprint
 *   apps/ios/.../Networking/MapPresenceEngine.swift    the two safety invariants, emitFix,
 *                                                      killSwitch, client-side authorization
 *   apps/ios/.../Networking/MapVisibilityState.swift   ghost is the default; the 24h auto-ghost
 *   apps/ios/.../Networking/MapLocationProvider.swift  the provider is stopped while ghosted
 *   apps/ios/.../Networking/MapKeyStore.swift          keys in the Keychain, not the database
 *   apps/ios/.../Models/MapModels.swift                GhostDuration, MapPresenceState windows,
 *                                                      the allow-list expansion rule
 *   apps/ios/.../Main/MapTabView.swift                 the "Visible to N people" pill, ghost sheet
 *   apps/ios/.../Main/Settings/PrivacySettingsView.swift   ghost mirror + the kill switch
 *   apps/ios/.../Main/LocationComposeSheet.swift       15 min / 1 hour / 8 hours, no indefinite
 *   apps/ios/.../Networking/LocationShareEngine.swift  1:1 + group (MLS) live shares, rekey
 *   apps/android/.../net/MapPresenceEngine.kt          Android parity, incl. the kill switch
 *
 * TWO THINGS DELIBERATELY NOT SAID HERE, because they are not true today:
 *   - No "turn off map tiles" switch is claimed. `MapTilePreference` exists in
 *     LocationPinBubble.swift but nothing in the shipped UI writes it, so the page
 *     states the tile leak and stops there rather than promising a control.
 *   - No store links. There are none.
 */

/** The sealed fixes drawn along the timeline. x is in the SVG's user units. */
const VISIBLE_A = [88, 128, 168, 208, 248, 284];
const VISIBLE_C = [496, 532, 568, 604, 640, 676];

/** Delay that lines a fix up with the sweeping playhead: same 9s cycle, offset by x. */
function blipDelay(x: number): string {
  return `${(((x - 60) / 640) * 9).toFixed(2)}s`;
}

const GATES = [
  {
    title: 'Ghost Mode is the default, and it is a hard local gate.',
    body:
      'A new install appears to nobody. While you are ghosted, Voiid does not take your ' +
      'position and quietly withhold it — the location provider is stopped, so no fix is ' +
      'ever taken. A missing setting is read as ghosted, never as visible.',
    glyph: 'eye-off' as const,
  },
  {
    title: 'The audience starts empty and only ever grows by name.',
    body:
      'There is no “share with everyone” and no one-tap “all my contacts”. Picking a group ' +
      'is a shortcut that expands to individuals the moment you tap it and is stored as ' +
      'individuals — so leaving that group later never silently keeps someone on your list. ' +
      'There is no “everyone except…” mode, because its default is “visible”.',
    glyph: 'group' as const,
  },
  {
    title: 'Only then does a row exist on our server.',
    body:
      'Going visible creates one row that records a share exists, who it is for, and when ' +
      'it expires. Before you opt in there is nothing to query, nothing to leak and nothing ' +
      'to subpoena, because the row has not been written.',
    glyph: 'shield' as const,
  },
];

const STATES = [
  {
    key: 'live',
    name: 'Live',
    when: 'Last fix under 15 minutes old',
    body: 'Full-colour avatar, on the map, where they are.',
  },
  {
    key: 'stale',
    name: 'Stale',
    when: '15 minutes to 8 hours',
    body:
      'Desaturated, with a clock and “last seen 2 h ago”. The last known position is kept ' +
      '— a phone in a tunnel is not a phone that stopped sharing.',
  },
  {
    key: 'aged',
    name: 'Aged out',
    when: 'Over 8 hours, no stop received',
    body:
      'The avatar leaves the map and moves to a list. The position is still theirs to ' +
      'explain; we just stop drawing it as current.',
  },
  {
    key: 'off',
    name: 'Not sharing',
    when: 'They turned it off, or the share expired',
    body:
      'The cached position is erased. They appear in a “Not sharing” list with no location ' +
      'at all — not a faded one, not an old one.',
  },
];

const LIMITS = [
  {
    title: 'Map tiles leak the viewport to Apple or Google.',
    body:
      'Drawing a map means asking someone for tiles: Apple Maps on iOS, Google Maps on ' +
      'Android. Voiid’s server stays blind; the tile provider does not. What we do control, ' +
      'we did — every thumbnail is rendered on your own device, so a sender’s position is ' +
      'never uploaded as a picture on a viewer’s behalf, and a friend’s coordinate is never ' +
      'sent to a geocoder to be turned into a street address.',
    glyph: 'globe' as const,
  },
  {
    title: 'The relay cannot check who is allowed to receive a fix.',
    body:
      'The WebSocket process has no database, so it cannot verify that a recipient is on ' +
      'your list — it only knows who sent the frame. Your friends’ phones do that check ' +
      'instead, dropping any fix from a share they hold no key for. Someone relaying frames ' +
      'at strangers gains nothing: without the key it decrypts to noise.',
    glyph: 'device' as const,
  },
  {
    title: 'Revoking stops the next fix. It cannot un-see the last one.',
    body:
      'Anyone who could see your position could have written it down or screenshotted it. ' +
      'Revocation and Ghost Mode are about what happens next, and no wording on this page ' +
      'or in the app pretends otherwise.',
    glyph: 'key' as const,
  },
  {
    title: 'We know a share exists, who it is with, and when it ends.',
    body:
      'That is real metadata and it is ours. The relay additionally sees who sent a frame, ' +
      'an opaque share id, the list of recipients and the timing — the same class of ' +
      'metadata as a typing indicator. It never sees a coordinate.',
    glyph: 'note' as const,
  },
  {
    title: 'There is no “who viewed your location”, and no history.',
    body:
      'View receipts would need a channel that reports your friends’ browsing back to them, ' +
      'so we did not build one. Neither are there geofences, arrival alerts or trails: Voiid ' +
      'keeps exactly one position per contact and overwrites it in place.',
    glyph: 'eye-off' as const,
  },
];

export default function MapPage() {
  return (
    <>
      <Hero
        hue="map"
        eyebrow="The Map"
        title={<>You are on nobody&rsquo;s map until you name them.</>}
        lede={
          <>
            Voiid&rsquo;s Map opens ghosted. Nothing is shared, no position is taken, and no
            row exists on our server &mdash; until you pick people one at a time. Every fix
            that then leaves your phone is sealed to exactly those people, and to nobody
            else, us included.
          </>
        }
        badges={
          <>
            <E2EEBadge state="e2ee" size="md" label="Positions — end-to-end encrypted" />
            <span className={styles.heroChip}>
              <Glyph name="eye-off" size={16} />
              Ghosted by default
            </span>
          </>
        }
        actions={
          <ButtonRow>
            <Button href="#server-row" size="lg">
              See the whole server row
            </Button>
            <Button href="/privacy" variant="secondary" size="lg">
              Read the privacy architecture
            </Button>
          </ButtonRow>
        }
        aside={
          <PhoneMockup
            hue="map"
            size="md"
            tilt="left"
            label="The Voiid Map. A pill across the top reads “Visible to 3 people”. Three friends who chose to share are drawn on the map, one of them faded because their last fix is hours old. Below, a row reads “Not sharing — Rhea”."
          >
            <PhoneAppBar
              title="Map"
              subtitle="Ghost Mode off"
              back={false}
              trailing={<Glyph name="eye-off" size={16} />}
            />

            <div className={styles.mapScreen}>
              {/* The map itself: streets, a park and a river, all drawn in CSS. */}
              <div className={styles.mapCanvas} aria-hidden="true">
                <span className={styles.mapGrid} />
                <span className={styles.mapPark} />
                <span className={styles.mapRiver} />

                {/* The one amber moment on this page — the app's own accent pill,
                 * which exists to make "you are broadcasting" impossible to miss. */}
                <span className={styles.visiblePill}>
                  <span className={styles.visibleDot} />
                  Visible to 3 people
                </span>

                <span className={[styles.pin, styles.pinA].join(' ')}>AK</span>
                <span className={[styles.pin, styles.pinB].join(' ')}>M</span>
                <span className={[styles.pin, styles.pinStale].join(' ')}>S</span>

                <span className={styles.selfDot} />
              </div>

              <div className={styles.mapSheet} aria-hidden="true">
                <span className={styles.mapSheetGrip} />
                <span className={styles.mapSheetRow}>
                  <PhoneAvatar initials="R" size={22} seed={1} />
                  <span className={styles.mapSheetText}>
                    <span className={styles.mapSheetName}>Rhea</span>
                    <span className={styles.mapSheetMeta}>Not sharing</span>
                  </span>
                </span>
                <span className={styles.mapSheetRow}>
                  <PhoneAvatar initials="S" size={22} seed={3} />
                  <span className={styles.mapSheetText}>
                    <span className={styles.mapSheetName}>Sana</span>
                    <span className={styles.mapSheetMeta}>Last seen 2 h ago</span>
                  </span>
                </span>
              </div>
            </div>
          </PhoneMockup>
        }
      />

      {/* ---- the three gates -------------------------------------------------- */}
      <Section
        id="gates"
        hue="map"
        eyebrow="Before anyone sees anything"
        title="Three gates stand between you and a stranger’s screen."
        lede={
          <>
            A friend map is the most dangerous surface in a messaging app, so it is the one
            we built defensively. None of these three is a setting we recommend you find.
            They are the state the app ships in.
          </>
        }
      >
        <ol className={styles.gates}>
          {GATES.map((gate, i) => (
            <li key={gate.title} className={styles.gate}>
              <span className={styles.gateMark} aria-hidden="true">
                <span className={styles.gateNum}>{i + 1}</span>
                <span className={styles.gateGlyph}>
                  <Glyph name={gate.glyph} size={18} />
                </span>
              </span>
              <div className={styles.gateBody}>
                <h3 className={styles.gateTitle}>{gate.title}</h3>
                <p className={styles.gateText}>{gate.body}</p>
              </div>
            </li>
          ))}
        </ol>
      </Section>

      {/* ---- the centrepiece: what ghosting actually does to the key ---------- */}
      <Section
        id="ghost"
        hue="map"
        tone="raised"
        eyebrow="Ghost Mode"
        title="Going dark is cryptographically dark."
        lede={
          <>
            Ghost Mode is not a flag on a server we promise to honour. Your phone stops
            taking fixes, and when you come back it comes back under a different key.
            Here is one day of that, drawn to scale.
          </>
        }
      >
        <figure className={styles.figure}>
          <div className={['scrollX', styles.timelineScroll].join(' ')}>
            <svg
              className={styles.timeline}
              viewBox="0 62 760 236"
              role="img"
              aria-label="A timeline of one day of Map visibility, in three phases. In the first phase you are visible and sealed position fixes leave your phone under key A. In the middle phase Ghost Mode is on: the band is empty, because no fix is taken at all, and key A stops being used. In the third phase ghost lifts, a fresh key B is minted and handed to your audience, and fixes resume under key B — so nothing from the new session can be read with the old key."
            >
              <defs>
                <pattern
                  id="voiid-map-hatch"
                  width="9"
                  height="9"
                  patternUnits="userSpaceOnUse"
                  patternTransform="rotate(45)"
                >
                  <line className={styles.hatch} x1="0" y1="0" x2="0" y2="9" />
                </pattern>
              </defs>

              {/* phase bands */}
              <rect className={styles.bandOn} x="60" y="100" width="240" height="92" rx="14" />
              <rect className={styles.bandGhost} x="308" y="100" width="154" height="92" rx="14" />
              <rect className={styles.bandOn} x="470" y="100" width="230" height="92" rx="14" />

              {/* phase captions */}
              <text className={styles.phase} x="60" y="86">VISIBLE</text>
              <text className={styles.phase} x="308" y="86">GHOST</text>
              <text className={styles.phase} x="470" y="86">VISIBLE AGAIN</text>

              {/* sealed fixes — one small packet per fix, lit as the playhead passes */}
              {VISIBLE_A.map((x) => (
                <rect
                  key={`a${x}`}
                  className={styles.fix}
                  style={{ ['--blip-delay' as string]: blipDelay(x) }}
                  x={x - 6}
                  y="140"
                  width="12"
                  height="12"
                  rx="3.5"
                />
              ))}
              {VISIBLE_C.map((x) => (
                <rect
                  key={`c${x}`}
                  className={styles.fix}
                  style={{ ['--blip-delay' as string]: blipDelay(x) }}
                  x={x - 6}
                  y="140"
                  width="12"
                  height="12"
                  rx="3.5"
                />
              ))}

              <text className={styles.bandNoteOn} x="180" y="176">sealed fix every few minutes</text>
              <text className={styles.bandNoteGhost} x="385" y="141">no fix is taken</text>
              <text className={styles.bandNoteGhostSub} x="385" y="162">the GPS is never asked</text>
              <text className={styles.bandNoteOn} x="585" y="176">sealed fix every few minutes</text>

              {/* what each key can read */}
              <rect className={styles.keyBar} x="60" y="224" width="240" height="12" rx="6" />
              <rect className={styles.keyBar} x="470" y="224" width="230" height="12" rx="6" />
              <line className={styles.keyGap} x1="308" y1="230" x2="462" y2="230" />

              <text className={styles.keyLabel} x="60" y="258">key A</text>
              <text className={styles.keySub} x="60" y="278">minted when you went visible</text>
              <text className={styles.keyLabel} x="470" y="258">key B</text>
              <text className={styles.keySub} x="470" y="278">minted when ghost lifted</text>
              <text className={styles.keyGapLabel} x="385" y="258">key A reads nothing here</text>

              {/* the playhead: one 9s pass across the whole day */}
              <g className={styles.playhead}>
                <line x1="60" y1="92" x2="60" y2="288" />
                <circle cx="60" cy="92" r="4" />
              </g>
            </svg>
          </div>
          <figcaption className={styles.figCaption}>
            Every visibility session mints its own random 32-byte key on your phone and hands
            it to your audience inside an ordinary end-to-end encrypted message. The server
            never carries the key, only the sealed fixes it cannot open.
          </figcaption>
        </figure>

        <div className={styles.ghostFacts}>
          <div className={styles.fact}>
            <h3 className={styles.factTitle}>Ghost on your terms, or on a timer</h3>
            <p className={styles.factBody}>
              For 1 hour, until tomorrow, or until you turn it off &mdash; and the toggle
              defaults to the last one. It is mirrored in Settings &rarr; Privacy, so you
              never have to open the Map to disappear from it.
            </p>
          </div>
          <div className={styles.fact}>
            <h3 className={styles.factTitle}>A 24-hour dead-man switch</h3>
            <p className={styles.factBody}>
              If you have not opened Voiid in 24 hours your phone stops emitting on its own.
              Visibility is not something you get to forget about for a week.
            </p>
          </div>
          <div className={styles.fact}>
            <h3 className={styles.factTitle}>One row that ends everything</h3>
            <p className={styles.factBody}>
              Settings &rarr; Privacy &rarr; <em>Stop all location sharing</em> ends every
              outbound share, clears your allow-list and turns Ghost Mode on. It is also on
              a long-press of the Map tab, for when reaching Settings is not realistic.
            </p>
          </div>
        </div>
      </Section>

      {/* ---- one ciphertext, however many friends ----------------------------- */}
      <Section
        id="one-ciphertext"
        hue="map"
        eyebrow="How a position travels"
        title="Encrypted once. Copied, never read."
      >
        <Split
          align="start"
          aside={
            <figure className={styles.figure}>
              <svg
                className={styles.fanout}
                viewBox="0 0 420 300"
                role="img"
                aria-label="Your phone encrypts one position fix a single time and hands the sealed packet to the relay. The relay holds no key — it copies the same bytes to each of the four people on your list, whose phones hold the key and can open it."
              >
                {/* your phone */}
                <rect className={styles.node} x="18" y="118" width="60" height="64" rx="12" />
                <rect className={styles.nodeScreen} x="27" y="127" width="42" height="46" rx="7" />
                <text className={styles.fanLabel} x="48" y="200">you</text>

                {/* the one sealed packet, riding the wire */}
                <line className={styles.wire} x1="80" y1="150" x2="166" y2="150" />
                <g className={styles.packet}>
                  <rect x="-11" y="-11" width="22" height="22" rx="5" />
                  <path d="M -4.5 -1 v -4 a 4.5 4.5 0 0 1 9 0 v 4" />
                </g>

                {/* the relay */}
                <rect className={styles.relay} x="168" y="112" width="86" height="76" rx="14" />
                <g className={styles.noKey}>
                  <circle cx="203" cy="150" r="7" />
                  <path d="M 210 150 h 18 M 225 150 v 6 M 219 150 v 5" />
                  <path d="M 190 137 L 232 163" />
                </g>
                <text className={styles.fanLabel} x="211" y="206">relay</text>
                <text className={styles.fanSub} x="211" y="222">no key, no database row</text>

                {/* four recipients, each holding the key */}
                {[46, 106, 166, 226].map((y, i) => (
                  <g key={y}>
                    <path
                      className={styles.fanWire}
                      style={{ ['--fan-delay' as string]: `${i * 0.32}s` }}
                      d={`M 254 150 C 300 150, 300 ${y + 22}, 344 ${y + 22}`}
                    />
                    <rect className={styles.node} x="344" y={y} width="44" height="44" rx="10" />
                    <g className={styles.hasKey} transform={`translate(354 ${y + 22})`}>
                      <circle cx="5" cy="0" r="4.5" />
                      <path d="M 9.5 0 h 13 M 20 0 v 4.5 M 15.5 0 v 3.5" />
                    </g>
                  </g>
                ))}
                <text className={styles.fanLabel} x="366" y="292">your list</text>
              </svg>
              <figcaption className={styles.figCaption}>
                One encryption, one ciphertext, four deliveries. Adding a fifth person adds a
                copy, not a second encryption &mdash; and never a second thing we can read.
              </figcaption>
            </figure>
          }
        >
          <p className={styles.copy}>
            A fix is small: a share id, a counter, a timestamp, a latitude, a longitude and
            how accurate your phone thinks it is. Your device encrypts that once, under the
            key only your audience holds, and hands the single sealed blob to a relay that
            copies bytes to each of them.
          </p>
          <p className={styles.copy}>
            It is never written to our database. It never becomes a push notification &mdash;
            deliberately, because a push would tell Apple and Google that you had started
            sharing. If nobody&rsquo;s connection is open, the relay keeps only the newest
            blob for five minutes and then drops it. Stale positions are worse than none, so
            there is no queue to replay.
          </p>

          <ul className={styles.tally}>
            <li>
              <strong>1</strong>
              <span>encryption per fix, whatever the size of your audience</span>
            </li>
            <li>
              <strong>0</strong>
              <span>database rows written per fix</span>
            </li>
            <li>
              <strong>0</strong>
              <span>push notifications sent per fix</span>
            </li>
            <li>
              <strong>1</strong>
              <span>position stored per contact, overwritten in place</span>
            </li>
          </ul>

          <Callout title="One key per session, and no forward secrecy inside it.">
            <p>
              Everyone in your audience holds the same key for as long as that visibility
              session lasts, so whoever holds it can read every fix in that session. Starting
              a new session &mdash; going visible again after a ghost, or removing one person
              &mdash; always means a new key. We cannot do better yet: the encryption core has
              no key-derivation step to build a chain from, and claiming the property anyway
              would be the actual lie. Because no fix is ever stored, the window is the live
              stream itself.
            </p>
          </Callout>
        </Split>
      </Section>

      {/* ---- the whole server row -------------------------------------------- */}
      <Section
        id="server-row"
        hue="map"
        tone="inset"
        eyebrow="What we store"
        title="This is the entire row."
        lede={
          <>
            Not a summary of it. The two tables below are everything our database holds about
            a location share, and the second list is the part that matters.
          </>
        }
      >
        <div className={styles.rowCard}>
          <div className={styles.rowCol}>
            <h3 className={styles.rowHead}>
              <Glyph name="note" size={17} />
              What a share row records
            </h3>
            <dl className={styles.cols}>
              <div className={styles.col}>
                <dt>a share id</dt>
                <dd>an opaque identifier, meaningless on its own</dd>
              </div>
              <div className={styles.col}>
                <dt>whose share it is</dt>
                <dd>the account that started it</dd>
              </div>
              <div className={styles.col}>
                <dt>which kind</dt>
                <dd>Map presence, or a live share inside one conversation</dd>
              </div>
              <div className={styles.col}>
                <dt>started, expires, ended</dt>
                <dd>three timestamps; every share has an expiry, none is indefinite</dd>
              </div>
              <div className={styles.col}>
                <dt>who it is for</dt>
                <dd>one line per person, and when each was revoked</dd>
              </div>
            </dl>
          </div>

          <div className={styles.rowCol}>
            <h3 className={[styles.rowHead, styles.rowHeadAbsent].join(' ')}>
              <Glyph name="eye-off" size={17} />
              Columns that do not exist
            </h3>
            <ul className={styles.absent}>
              <li>latitude</li>
              <li>longitude</li>
              <li>accuracy</li>
              <li>altitude, speed, heading</li>
              <li>any ciphertext</li>
              <li>any key</li>
              <li>last-seen time</li>
              <li>update count</li>
              <li>any position, ever recorded</li>
            </ul>
            <p className={styles.absentNote}>
              There is deliberately no HTTP endpoint that accepts a coordinate either, and a
              guard on every location route rejects a request body containing one &mdash;
              because a route that exists is a route somebody eventually posts a latitude to.
            </p>
          </div>
        </div>

        <p className={styles.pullQuote}>
          Voiid&rsquo;s servers know that a share exists, who it is with, and when it ends.
          They never know where you are, whether you moved, or how often you updated.
        </p>
      </Section>

      {/* ---- the four states -------------------------------------------------- */}
      <Section
        id="states"
        hue="map"
        eyebrow="Reading the map"
        title="“Lost signal” and “stopped sharing” are different words, different shapes."
        lede={
          <>
            Conflating them is how a map hurts someone. A person whose phone died must never
            look like a person who chose to disappear, and the reverse matters even more.
          </>
        }
      >
        <div className={styles.states}>
          {STATES.map((s) => (
            <div key={s.key} className={styles.state}>
              <span
                className={[styles.marker, styles[`marker-${s.key}`]].join(' ')}
                aria-hidden="true"
              />
              <h3 className={styles.stateName}>{s.name}</h3>
              <p className={styles.stateWhen}>{s.when}</p>
              <p className={styles.stateBody}>{s.body}</p>
            </div>
          ))}
        </div>

        <Callout tone="note" glyph="shield" title="The load-bearing difference.">
          <p>
            An explicit stop <strong>erases</strong> the position your phone had cached for
            that person. An age-out <strong>keeps</strong> it. That asymmetry is the whole
            reason you can tell &ldquo;they turned it off&rdquo; from &ldquo;their battery
            went&rdquo; &mdash; and it is why Voiid draws no trails, keeps no history, and
            wipes anything older than eight hours on a cold start.
          </p>
        </Callout>
      </Section>

      {/* ---- live location inside a conversation ------------------------------ */}
      <Section
        id="live-share"
        hue="map"
        tone="raised"
        eyebrow="In a chat"
        title="Live location is a tighter, shorter thing on purpose."
        lede={
          <>
            The Map is an ambient standing state. Sharing live inside a conversation is an
            explicit act with an end time, so it is built to different rules &mdash; more
            precise, more visible while it runs, and never open-ended.
          </>
        }
      >
        <Split
          reverse
          align="start"
          aside={
            <PhoneMockup
              hue="map"
              size="md"
              tilt="right"
              label="A group chat in Voiid. A live location card shows a map thumbnail, the line “Live until 15:42” and a Stop control, above a note saying the share ends on its own."
            >
              <PhoneAppBar
                title="Design Team"
                subtitle="7 people · end-to-end encrypted"
                trailing={<Glyph name="group" size={16} />}
              />
              <div className={styles.thread}>
                <ChatBubble side="received">We&rsquo;re here &mdash; corner table by the window.</ChatBubble>
                <ChatBubble side="received">Are you close? We&rsquo;ll hold it.</ChatBubble>
                <ChatBubble side="sent" meta="15:12">
                  Two stops away. Sharing live for an hour.
                </ChatBubble>

                <div className={styles.locCard} aria-hidden="true">
                  <span className={styles.locMap}>
                    <span className={styles.locGrid} />
                    <span className={styles.locPulse} />
                    <span className={styles.locPin} />
                  </span>
                  <span className={styles.locFoot}>
                    <span className={styles.locFootText}>
                      <span className={styles.locTitle}>Live until 15:42</span>
                      <span className={styles.locMeta}>Accurate to about 20 m</span>
                    </span>
                    <span className={styles.locStop}>Stop</span>
                  </span>
                </div>

                <div className={styles.systemNote}>
                  <Glyph name="lock" size={12} />
                  Everyone in Design Team (6 people) can see this until 15:42.
                </div>
              </div>
              <div className={styles.composer}>
                <span className={styles.composerField}>Message</span>
                <PhoneAvatar initials="D" size={26} seed={2} />
              </div>
            </PhoneMockup>
          }
        >
          <dl className={styles.spec}>
            <div>
              <dt>15 minutes, 1 hour, or 8 hours</dt>
              <dd>
                There is no indefinite option, in a chat or on the Map. The sheet names the
                audience above the picker &mdash; &ldquo;everyone in Design Team (7 people)
                will see your live location&rdquo; &mdash; so nobody shares into a room they
                had not counted.
              </dd>
            </div>
            <div>
              <dt>The timer is the guarantee, not the courtesy</dt>
              <dd>
                Both phones hold the end time locally, and the recipient hides the marker at
                that moment with no network contact at all. It works if you are offline, out
                of battery, uninstalled, or actively hostile. Everything else &mdash; the
                instant stop, the durable stop message that reaches someone who was offline
                &mdash; is an optimisation on top of that.
              </dd>
            </div>
            <div>
              <dt>Removing one person re-keys the rest</dt>
              <dd>
                Revoke a single recipient and they get a stop, then everyone still watching
                gets a fresh key. From that moment the person you removed decrypts nothing
                further, rather than being politely asked not to look.
              </dd>
            </div>
            <div>
              <dt>Impossible to forget it is running</dt>
              <dd>
                A banner sits under the header of your chat list and the conversation, with
                the time remaining and a Stop button. iOS shows its own background-location
                indicator; Android shows an ongoing notification with a Stop action. A local
                reminder fires two minutes before it ends.
              </dd>
            </div>
            <div>
              <dt>Groups work the same way</dt>
              <dd>
                A pin or a live share in a group rides the same encrypted group messaging as
                everything else in it. A pin is just a message: it sits in the history like
                any other, and carries the label you typed &mdash; we never resolve a
                coordinate into an address, because that would hand a friend&rsquo;s position
                to a geocoder.
              </dd>
            </div>
          </dl>
        </Split>
      </Section>

      {/* ---- the honest ledger ------------------------------------------------ */}
      <Section
        id="limits"
        hue="map"
        eyebrow="The honest part"
        title="What this design does not give you."
        lede={
          <>
            Collected in one place so that nobody &mdash; including us &mdash; ships a screen
            that promises them.
          </>
        }
        width="narrow"
      >
        <ul className={styles.limits}>
          {LIMITS.map((l) => (
            <li key={l.title} className={styles.limit}>
              <span className={styles.limitGlyph} aria-hidden="true">
                <Glyph name={l.glyph} size={18} />
              </span>
              <div>
                <h3 className={styles.limitTitle}>{l.title}</h3>
                <p className={styles.limitBody}>{l.body}</p>
              </div>
            </li>
          ))}
        </ul>
      </Section>

      <CTA
        hue="map"
        title="Judge this page against the architecture, not the adjectives."
        lede={
          <>
            Everything here is a design decision you can hold us to: ghost by default, an
            allow-list that starts empty, a fresh key after every dark period, and a database
            row with no coordinate in it.
          </>
        }
        actions={
          <ButtonRow align="center">
            <Button href="/privacy" size="lg">
              What we can and cannot see
            </Button>
            <Button href="/messaging" variant="secondary" size="lg">
              How messaging works
            </Button>
          </ButtonRow>
        }
        note="Map tiles come from Apple Maps on iOS and Google Maps on Android — the one part of this feature that is not ours, and the one part we cannot make blind."
      />
    </>
  );
}
