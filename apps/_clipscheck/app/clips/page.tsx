import type { Metadata } from 'next';
import { Hero } from '../../components/Hero';
import { Section, Grid, Split } from '../../components/Section';
import { FeatureCard, StatLine } from '../../components/FeatureCard';
import { CTA } from '../../components/CTA';
import { Button, ButtonRow } from '../../components/Button';
import { E2EEBadge } from '../../components/E2EEBadge';
import { Callout } from '../../components/Callout';
import { Glyph } from '../../components/Glyph';
import { PhoneMockup, PhoneAppBar, PhoneAvatar } from '../../components/PhoneMockup';
import styles from './page.module.css';

/*
 * CLIPS — the page that has to be honest or it is worthless.
 *
 * Every claim below is checked against the code, not against the pitch:
 *   - Not E2EE, deliberately: database/migrations/022_clips.sql header (media, caption
 *     and cover are plaintext in R2) and 029_creator_profiles.sql header (profile,
 *     follows, likes, comments are server-readable). Both say why in the same words
 *     this page uses: a broadcast has no fixed recipient set to encrypt to, and a
 *     server that cannot read a row cannot count it.
 *   - A follow grants NO messaging right: 029 header, backend/api/src/routes/creators.ts
 *     header, and 020_reachability.sql, which defines the only three ways a conversation
 *     opens. `creator_follows` is read by creators.ts and by nothing else in the API —
 *     verified by grep, and that is the invariant the page states.
 *   - Limits: MAX_DURATION_MS 90s, MAX_BYTE_SIZE 100 MB, MAX_CLIPS_PER_DAY 30,
 *     MAX_CAPTION_LEN 2200 — all in backend/api/src/routes/clips.ts.
 *   - Ten looks, same order on both platforms: ClipFilter in
 *     apps/ios/.../Clips/ClipEditor.swift and apps/android/.../clips/ClipEditor.kt.
 *   - Three renditions exported on device: 023_clips_renditions.sql + ClipQuality.swift.
 *   - Explore is newest-first keyset paging (GET /clips/feed); Following is a separate
 *     query (GET /creators/feed/following), not a filter over Explore.
 *   - Handle rules: 029 (grammar, shared namespace, reserved names) and creators.ts
 *     (30-day rename window, 301 to the current handle).
 *   - No store links exist. Do not invent one.
 *
 * AMBER BUDGET: this page spends none. Nothing here carries `hue="games"`, no accent
 * button, no CTA accent, no PhoneRow badge. The page is entirely the clips hue.
 */

export const metadata: Metadata = {
  title: 'Clips',
  description:
    'Short public video, creator profiles and follows. Clips are not end-to-end ' +
    'encrypted and we explain exactly why — a broadcast has no recipient set to ' +
    'encrypt to. Following someone grants no right to message them.',
};

const LOOKS = [
  'Original',
  'Vivid',
  'Dramatic',
  'Mono',
  'Noir',
  'Fade',
  'Chrome',
  'Process',
  'Transfer',
  'Instant',
];

/** What the server can read, in the order a clip produces it. */
const SERVER_READS = [
  'The video file itself — stored as plain bytes, in up to three qualities',
  'The caption, up to 2,200 characters',
  'The cover image the grid draws instead of the video',
  'Your creator handle, display name, bio, link and public avatar',
  'Who follows whom, and every like and comment',
  'One row per clip per viewer, which is how a view is counted once',
];

/** What posting a clip does not change. */
const STILL_SEALED = [
  'Message text, photos, voice notes and files in any chat',
  'Voice and video calls, one to one and in a group',
  'Live location and the pins you drop into a conversation',
  'Moments, which are encrypted to an audience you named',
  'Your chat profile photo — a different, encrypted object from the public avatar',
];

/* ---------------------------------------------------------------------------
 * The mechanism diagram. Two panels drawn on identical geometry so the eye can
 * compare them: same author device, same server band, different bottom half.
 * That difference IS the argument — a moment has a recipient list, a clip does
 * not — so the drawing carries it rather than decorating a paragraph.
 * ------------------------------------------------------------------------ */

const MOMENT_LABEL =
  'Diagram: a moment posted from one phone becomes three separately sealed copies, ' +
  'one for each named recipient. They pass through the Voiid server, which sees three ' +
  'sealed blobs and holds no key, and arrive on the three recipients’ phones.';

const CLIP_LABEL =
  'Diagram: a clip posted from one phone becomes a single plain video file. It passes ' +
  'through the Voiid server, which can read it and counts every view, and is then ' +
  'available to an open audience — including people who have not signed up yet.';

function SealedDiagram() {
  const columns = [60, 160, 260];
  const names = ['Asha', 'Ravi', 'Meera'];

  return (
    <svg
      className={styles.diagram}
      viewBox="0 0 320 260"
      role="img"
      aria-label={MOMENT_LABEL}
    >
      {/* author */}
      <g className={styles.dgDevice}>
        <rect x="143" y="14" width="34" height="52" rx="9" />
        <rect x="148" y="21" width="24" height="38" rx="4" className={styles.dgScreen} />
      </g>
      <text x="160" y="82" className={styles.dgLabel} textAnchor="middle">
        you
      </text>

      {/* one sealed copy per recipient */}
      {columns.map((x) => (
        <g key={x}>
          <path
            d={`M160 88 C 160 96, ${x} 88, ${x} 100`}
            className={styles.dgWireSealed}
            fill="none"
          />
          <g className={styles.dgLock} transform={`translate(${x} 116)`}>
            <path d="M-6 -6 v -4 a 6 6 0 0 1 12 0 v 4" fill="none" />
            <rect x="-9" y="-6" width="18" height="14" rx="4" />
            <circle cx="0" cy="1" r="1.9" className={styles.dgLockPin} />
          </g>
          <line x1={x} y1="126" x2={x} y2="140" className={styles.dgWireSealed} />
        </g>
      ))}

      {/* the server band. The label lives INSIDE it: an outside caption would sit on
       * top of the left-hand wire at this width. */}
      <rect x="12" y="140" width="296" height="34" rx="10" className={styles.dgBand} />
      <text x="160" y="161" className={styles.dgBandText} textAnchor="middle">
        our server · three sealed blobs · no key
      </text>

      {/* recipients */}
      {columns.map((x, i) => (
        <g key={`r-${x}`}>
          <line x1={x} y1="174" x2={x} y2="192" className={styles.dgWireSealed} />
          <g className={styles.dgDevice}>
            <rect x={x - 13} y="192" width="26" height="42" rx="7" />
            <rect
              x={x - 9}
              y="197"
              width="18"
              height="30"
              rx="3"
              className={styles.dgScreen}
            />
          </g>
          <text x={x} y="250" className={styles.dgLabel} textAnchor="middle">
            {names[i]}
          </text>
        </g>
      ))}
    </svg>
  );
}

function BroadcastDiagram() {
  /* Five viewers; the last two are drawn dashed — they are the people who have not
   * signed up yet, and they are the reason there is nobody to encrypt to. */
  const viewers = [
    { x: 40, known: true },
    { x: 100, known: true },
    { x: 160, known: true },
    { x: 222, known: false },
    { x: 280, known: false },
  ];

  return (
    <svg
      className={styles.diagram}
      viewBox="0 0 320 260"
      role="img"
      aria-label={CLIP_LABEL}
    >
      {/* author */}
      <g className={styles.dgDevice}>
        <rect x="143" y="14" width="34" height="52" rx="9" />
        <rect x="148" y="21" width="24" height="38" rx="4" className={styles.dgScreen} />
      </g>
      <text x="160" y="82" className={styles.dgLabel} textAnchor="middle">
        you
      </text>

      {/* one plain file. Its label sits BESIDE it rather than under it, so the wire
       * down to the server band does not run through the words. */}
      <line x1="160" y1="88" x2="160" y2="101" className={styles.dgWireOpen} />
      <g className={styles.dgFile} transform="translate(160 112)">
        <rect x="-13" y="-11" width="26" height="22" rx="3" />
        <path d="M-6 -4 L 5 2 L -6 8 Z" className={styles.dgPlay} />
      </g>
      <text x="180" y="116" className={styles.dgFileLabel}>
        one plain video file
      </text>

      {/* the server band */}
      <line x1="160" y1="123" x2="160" y2="140" className={styles.dgWireOpen} />
      <rect x="12" y="140" width="296" height="34" rx="10" className={styles.dgBandOpen} />
      <text x="160" y="161" className={styles.dgBandTextOpen} textAnchor="middle">
        our server · reads it · counts every view
      </text>

      {/* an open audience */}
      {viewers.map((v) => (
        <g key={v.x}>
          <path
            d={`M160 174 C 160 190, ${v.x} 184, ${v.x} 196`}
            className={styles.dgWireOpen}
            fill="none"
          />
          <g className={v.known ? styles.dgViewer : styles.dgViewerUnknown}>
            <circle cx={v.x} cy="206" r="8" />
            <path d={`M${v.x - 12} 228 a 12 12 0 0 1 24 0`} fill="none" />
          </g>
          {v.known ? null : (
            <text x={v.x} y="210" className={styles.dgQuestion} textAnchor="middle">
              ?
            </text>
          )}
        </g>
      ))}
      <text x="160" y="250" className={styles.dgLabel} textAnchor="middle">
        anyone — including people who have not signed up
      </text>
    </svg>
  );
}

/* ---------------------------------------------------------------------------
 * Phone screens. Both are illustrations of real screens in the app, drawn in
 * markup so they stay sharp, reflow, and do not need a CDN.
 * ------------------------------------------------------------------------ */

const TILES = [
  { views: '312', tall: false },
  { views: '1,204', tall: true },
  { views: '87', tall: false },
  { views: '2,610', tall: false },
  { views: '45', tall: false },
  { views: '908', tall: true },
  { views: '156', tall: false },
  { views: '73', tall: false },
  { views: '431', tall: false },
];

function ClipTiles({ from = 0, count = 9 }: { from?: number; count?: number }) {
  return (
    <div className={styles.tiles}>
      {TILES.slice(from, from + count).map((tile, i) => (
        <span
          key={`${tile.views}-${i}`}
          className={[styles.tile, tile.tall ? styles.tileAlt : ''].filter(Boolean).join(' ')}
        >
          <span className={styles.tileViews}>
            <Glyph name="clips" size={9} />
            {tile.views}
          </span>
        </span>
      ))}
    </div>
  );
}

function ExploreScreen() {
  return (
    <>
      <div className={styles.clipsBar}>
        <span className={styles.clipsBarTitle}>Clips</span>
        <span className={styles.clipsBarIcon} aria-hidden="true">
          <Glyph name="clips" size={14} />
        </span>
      </div>
      <div className={styles.scopes}>
        <span className={[styles.scope, styles.scopeOn].join(' ')}>Explore</span>
        <span className={styles.scope}>Following</span>
      </div>
      <ClipTiles count={9} />
    </>
  );
}

function CreatorScreen() {
  return (
    <>
      <PhoneAppBar title="@ananya" subtitle="Creator profile" />
      <div className={styles.creator}>
        <div className={styles.creatorTop}>
          <PhoneAvatar initials="A" size={44} seed={1} />
          <div className={styles.creatorStats}>
            <span>
              <strong>24</strong>
              clips
            </span>
            <span>
              <strong>1,208</strong>
              followers
            </span>
            <span>
              <strong>86</strong>
              following
            </span>
          </div>
        </div>
        <span className={styles.creatorName}>Ananya R</span>
        <span className={styles.creatorBio}>
          Rooftop cooking, mostly at night. Bombay.
        </span>
        <span className={styles.creatorFollow}>Follow</span>
      </div>
      <ClipTiles from={2} count={6} />
    </>
  );
}

/* ------------------------------------------------------------------------ */

export default function ClipsPage() {
  return (
    <>
      <Hero
        hue="clips"
        eyebrow="Clips"
        title={<>Clips are public. That is a decision, not an oversight.</>}
        lede={
          <>
            Short video, creator profiles, follows and a camera with ten looks — built on
            the same account as your chats and deliberately outside their encryption. Our
            server stores the video, the caption and the cover in plain form, and counts
            every view. This page says why that had to be true, and what it costs you.
          </>
        }
        badges={
          <>
            <E2EEBadge
              state="public"
              size="md"
              detail="The server can read the video, the caption, the cover, and who liked or watched what."
            />
            <E2EEBadge
              state="e2ee"
              size="md"
              label="Messages · Calls · Map · Moments"
              detail="Unchanged by anything on this page. They are sealed to a known audience; a clip has none."
            />
          </>
        }
        actions={
          <ButtonRow>
            <Button href="#why" size="lg">
              Why it cannot be sealed
            </Button>
            <Button href="#follow" variant="secondary" size="lg">
              What a follow does not buy
            </Button>
          </ButtonRow>
        }
        aside={
          <PhoneMockup
            hue="clips"
            size="md"
            tilt="right"
            label="Illustration of the Clips grid in Voiid: an Explore and Following selector above a three-column grid of cover images, each with a view count."
          >
            <ExploreScreen />
          </PhoneMockup>
        }
      />

      {/* ---- the mechanism --------------------------------------------------- */}
      <Section
        id="why"
        hue="clips"
        width="wide"
        eyebrow="The mechanism"
        title="You cannot seal an envelope that has no address on it."
        lede={
          <>
            Encryption in Voiid works by sealing a message once for every device that is
            allowed to open it. That needs a list of recipients at the moment you post. A
            moment has one. A clip does not — and never will, because the point of a clip
            is to reach someone you have not met.
          </>
        }
      >
        <div className={styles.panels}>
          <figure className={styles.panel}>
            <div className={styles.panelHead}>
              <E2EEBadge state="e2ee" label="A moment" />
            </div>
            <SealedDiagram />
            <figcaption className={styles.panelCaption}>
              You chose the audience before you posted, so the app can seal one copy per
              recipient device. Our server relays three blobs it holds no key for.
            </figcaption>
          </figure>

          <figure className={styles.panel}>
            <div className={styles.panelHead}>
              <E2EEBadge state="public" label="A clip" />
            </div>
            <BroadcastDiagram />
            <figcaption className={styles.panelCaption}>
              There is no audience to seal it for. The people who will watch it include
              people who have not installed Voiid yet, so there is no key to encrypt to,
              and the file goes up as it is.
            </figcaption>
          </figure>
        </div>

        <Callout title="There is a second reason, and it is just as real.">
          <p>
            Clips carry a view count, a like count and a comment count on every tile, and
            those numbers have to be attributed by something neither the poster nor the
            viewer controls — otherwise a modified client could report any number it liked.
            A server that cannot read a row cannot count it. We would rather write that
            sentence down than ship a lock icon that means nothing.
          </p>
        </Callout>
      </Section>

      {/* ---- the ledger ------------------------------------------------------ */}
      <Section
        id="what-we-see"
        hue="clips"
        tone="raised"
        eyebrow="The exact scope"
        title="What our server can read, and what it still cannot."
        lede={
          <>
            The exception is scoped to Clips and the public identity behind them. It is not
            a precedent, and it does not reach sideways into anything else — those surfaces
            do not share a key with this one, because this one has no key.
          </>
        }
      >
        <div className={styles.ledger}>
          <div className={styles.ledgerCol}>
            <h3 className={styles.ledgerHead}>
              <span className={styles.ledgerIconOpen} aria-hidden="true">
                <Glyph name="broadcast" size={16} />
              </span>
              Readable by us
            </h3>
            <ul className={styles.ledgerList}>
              {SERVER_READS.map((item) => (
                <li key={item}>
                  <Glyph name="eye-off" size={15} className={styles.markOpen} />
                  <span>{item}</span>
                </li>
              ))}
            </ul>
          </div>

          <div className={styles.ledgerCol}>
            <h3 className={styles.ledgerHead}>
              <span className={styles.ledgerIconOk} aria-hidden="true">
                <Glyph name="lock" size={16} />
              </span>
              Untouched by any of this
            </h3>
            <ul className={styles.ledgerList}>
              {STILL_SEALED.map((item) => (
                <li key={item}>
                  <Glyph name="check" size={15} className={styles.markOk} />
                  <span>{item}</span>
                </li>
              ))}
            </ul>
          </div>
        </div>

        <Callout tone="note" title="Two things worth knowing before you post at all.">
          <p>
            A public identity is not created for you at signup. There is no creator profile
            behind your account until the first time you try to post a clip and pick a
            handle — so the overwhelming majority of people, who are here to message, never
            get a searchable public profile they did not ask for. And your public avatar is
            a separate image from your chat profile photo: the encrypted one is never reused
            on a public surface, because that would quietly publish it.
          </p>
        </Callout>
      </Section>

      {/* ---- the camera ------------------------------------------------------ */}
      <Section
        id="camera"
        hue="clips"
        eyebrow="Making one"
        title="The camera is the front door, not a picker."
        lede={
          <>
            Recording is where the app starts, with the library as a thumbnail inside the
            viewfinder — the same shape as every camera you already use. Everything after
            that is a description of an edit, so nothing is re-encoded until you post.
          </>
        }
      >
        <Grid columns={3} gap="md">
          <FeatureCard title="Multi-take, with speed per take" hue="clips" glyph="clips">
            <p>
              Each press and release records one take, at 0.3×, 0.5×, 1×, 2× or 3×. Takes
              bank up as you go and can be undone one at a time; they are joined into a
              single video only when you commit, so the shutter never stalls to re-mux
              mid-shoot.
            </p>
          </FeatureCard>

          <FeatureCard title="Ten looks, live in the viewfinder" hue="clips" glyph="sparkle">
            <p>
              {LOOKS.join(', ')} — the same ten, in the same order, on iPhone and Android.
              The preview is filtered frame by frame while the recording is written clean,
              so the look is applied exactly once, at export, and stays reversible until
              then.
            </p>
          </FeatureCard>

          <FeatureCard title="Trim and cover on real frames" hue="clips" glyph="device">
            <p>
              The editor plays video rather than showing a still, so you can judge a trim
              and hear the audio you are about to mute. The grid draws your cover, never
              the video, so you pick that frame yourself — or upload a different image
              entirely.
            </p>
          </FeatureCard>
        </Grid>

        <div className={styles.specs}>
          <StatLine label="Longest clip" value="90 s" />
          <StatLine label="Largest upload" value="100 MB" />
          <StatLine label="Exported on device" value="480 · 720 · 1080p" />
          <StatLine label="Posts per day" value="30" />
        </div>

        <div className={styles.note}>
          <p>
            Posting does not block on the upload: the tile appears in your grid straight
            away and the transfer runs behind it, and leaving the screen does not kill it.
            If it fails, the exported files are still on your phone, so retrying re-sends
            those bytes instead of making you shoot or export again. The clip only becomes
            a row other people can see once its files have actually landed — a client that
            dies mid-upload leaves no broken tile in anybody&rsquo;s feed.
          </p>
          <p>
            Playback picks one of the three qualities by connection rather than switching
            mid-stream, and the grid never plays video at all: it draws covers, which is
            what makes a scroll through it affordable on mobile data.
          </p>
        </div>
      </Section>

      {/* ---- the two feeds --------------------------------------------------- */}
      <Section
        id="feeds"
        hue="clips"
        eyebrow="Watching"
        title="Two feeds, both in plain time order."
        lede={
          <>
            Explore is every live clip, newest first. Following is a separate query over
            the creators you follow — a different source, not a filter laid over Explore.
          </>
        }
      >
        <Split
          reverse
          aside={
            <PhoneMockup
              hue="clips"
              size="md"
              tilt="left"
              label="Illustration of a creator profile in Voiid: handle, avatar, clip, follower and following counts, a bio, a Follow button, and a grid of that creator's covers."
            >
              <CreatorScreen />
            </PhoneMockup>
          }
        >
          <div className="prose">
            <p>
              There is no ranking model behind either grid. Nothing scores a clip, nothing
              scores you, and nothing decides what deserves the top of your screen — the
              order is the order things were posted in. Paging is by timestamp, so a clip
              posted while you are scrolling cannot make a tile repeat or vanish.
            </p>
            <p>
              We do record that you watched something: one row per clip per viewer, written
              after about two seconds of watching, which is what makes a view count once
              however many times you rewatch it. It is not used to sort your feed. Say the
              two sentences together, because both are true.
            </p>
            <p>
              A creator profile carries a handle, display name, bio, link, avatar and three
              counts. There is no endpoint that lists somebody&rsquo;s followers — you can
              see the numbers, and you can see your own Following feed, but the roster
              itself is not exposed to anyone.
            </p>
          </div>
        </Split>
      </Section>

      {/* ---- the rule that matters most -------------------------------------- */}
      <Section
        id="follow"
        hue="clips"
        tone="inset"
        eyebrow="The rule that matters most"
        title="A follow is not a messaging right."
        lede={
          <>
            Following is one-way and needs nobody&rsquo;s approval, because it grants
            exactly one thing: seeing content that was already public. A creator with a
            million followers has a million people who can watch their clips and zero
            extra people who can message them.
          </>
        }
      >
        <div className={styles.doorsWrap}>
          <h3 className={styles.doorsTitle}>The only three ways a conversation opens</h3>
          <ol className={styles.doors}>
            <li className={styles.door}>
              <span className={styles.doorNum} aria-hidden="true">
                1
              </span>
              <span className={styles.doorBody}>
                <strong>You are both in each other&rsquo;s contacts.</strong>
                The chat opens directly.
              </span>
            </li>
            <li className={styles.door}>
              <span className={styles.doorNum} aria-hidden="true">
                2
              </span>
              <span className={styles.doorBody}>
                <strong>They have you saved, but you do not have them.</strong>
                It arrives as a request you accept or decline. Having somebody&rsquo;s
                number is not by itself permission to reach them.
              </span>
            </li>
            <li className={styles.door}>
              <span className={styles.doorNum} aria-hidden="true">
                3
              </span>
              <span className={styles.doorBody}>
                <strong>They looked you up by @username and had your 6-digit PIN.</strong>
                Also a request. The PIN is something you hand out yourself.
              </span>
            </li>
          </ol>

          <p className={styles.doorShut}>
            <span className={styles.doorShutIcon} aria-hidden="true">
              <Glyph name="eye-off" size={18} />
            </span>
            <span className={styles.doorBody}>
              <strong>Following someone is not a fourth way.</strong>
              The follow graph is a separate table from the one that decides who may
              message you, and nothing in the messaging code reads it. Any future code
              that consults your followers to authorise a conversation is a bug, not a
              feature.
            </span>
          </p>
        </div>

        <div className={styles.handles}>
          <h3 className={styles.handlesTitle}>Your creator handle is not your chat username</h3>
          <p>
            A chat username is half of a credential — it is only useful to someone who also
            has your PIN. A creator handle is meant to be printed on a poster. Making them
            the same value would mean going public as a creator silently publishes your
            messaging lookup key, so they are separate fields with separate meanings.
          </p>
          <p>
            They do share one pool of names, though: taking <code>@ananya</code> as a
            creator makes it unavailable as a chat username and the other way round, since
            one name meaning two different people in one app is how impersonation starts. A
            handful of names — <code>admin</code>, <code>support</code>, <code>voiid</code>{' '}
            and the rest — belong to nobody. Handles are lowercase, 3 to 20 characters, and
            changeable once every 30 days; links to your old one keep resolving to the new
            one until somebody else legitimately takes it.
          </p>
        </div>
      </Section>

      {/* ---- deleting -------------------------------------------------------- */}
      <Section
        id="deleting"
        hue="clips"
        eyebrow="Taking one down"
        title="Deleting a clip is not a security operation."
        lede={
          <>
            It removes the clip from every feed and deletes the stored files, including all
            three qualities. It cannot reach the people who already watched it.
          </>
        }
        width="narrow"
      >
        <div className="prose">
          <p>
            The row itself survives as a tombstone rather than being erased outright, so
            counts and open comment lists on other people&rsquo;s phones do not vanish
            mid-scroll — but the video, the cover and every rendition are removed from
            storage, and a lifecycle rule on the bucket is the backstop if that call fails.
          </p>
          <p>
            The honest part is the second sentence: a clip was never encrypted, so anyone
            who watched it could have kept it, and deleting it cannot change that. The
            confirmation in the app says exactly this. It is the difference between
            unpublishing and unsaying, and only one of those is something software can do.
          </p>
          <p>
            Our own takedowns work the same way and are reversible: a removed clip is
            hidden rather than destroyed, the reason is recorded, and every moderator
            action is written to an audit log that survives the moderator&rsquo;s account.
            &ldquo;Who removed this and why&rdquo; has to have an answer, or moderation is
            something that happens to people rather than something anyone is accountable
            for.
          </p>
        </div>
      </Section>

      <CTA
        hue="clips"
        title="One line, if you keep only one."
        lede={
          <>
            Clips are public and our server reads them. Your messages, calls, location and
            moments are not, and it cannot. Following someone buys nobody a way into your
            inbox. All three of those sentences are load-bearing.
          </>
        }
        actions={
          <ButtonRow align="center">
            <Button href="/privacy" size="lg">
              Read the privacy architecture
            </Button>
            <Button href="/messaging" variant="secondary" size="lg">
              How messaging is protected
            </Button>
          </ButtonRow>
        }
        note="iOS and Android builds are still in testing. Store links will appear on this site once they exist, and not before."
      />
    </>
  );
}
