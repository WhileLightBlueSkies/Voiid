import type { Metadata } from 'next';
import { Hero } from '../../components/Hero';
import { Section, Grid } from '../../components/Section';
import { CryptoTable, type PrimitiveRow } from '../../components/CryptoTable';
import { CryptoStack, type StackLayer } from '../../components/CryptoStack';
import { Callout } from '../../components/Callout';
import { Reveal } from '../../components/Reveal';
import { CTA } from '../../components/CTA';
import { Button, ButtonRow } from '../../components/Button';
import { Glyph, type GlyphName } from '../../components/Glyph';
import { LockMotif } from '../../components/LockMotif';
import styles from './page.module.css';

export const metadata: Metadata = {
  title: 'Encryption — what we use and what we built',
  description:
    'Every cryptographic primitive Voiid relies on, named: the vetted libraries we did ' +
    'not invent, and the parts we wrote ourselves. Written so it can be checked.',
};

/*
 * EVERY ROW IS CHECKED AGAINST packages/e2e-core (Cargo.toml deps + SECURITY.md).
 * Do not claim padding (none exists), RLS (access control is API-side), or an
 * audit (there is none yet). The PQ 1:1 handshake exists but is compile-gated
 * off pending review — say that, do not imply it ships.
 */

type Built = {
  glyph: GlyphName;
  title: string;
  body: string;
};

/* Vetted, off-the-shelf. If a version bumps in e2e-core/Cargo.toml, bump here.
 * `spec` names what a reader would actually go and look up — the RFC number where
 * one exists, the maintaining body otherwise. */
const PRIMITIVES: PrimitiveRow[] = [
  {
    name: 'vodozemac',
    role: 'One-to-one messages',
    spec: 'Matrix.org · Apache-2.0',
    body:
      'The Signal-style Double Ratchet implementation maintained by the Matrix.org ' +
      'foundation. Every direct chat advances through it. We evaluated libsignal and ' +
      'chose this instead, deliberately.',
  },
  {
    name: 'OpenMLS',
    role: 'Group messages',
    spec: 'RFC 9420',
    body:
      'Message Layer Security exactly as specified by the IETF standard for encrypted ' +
      'groups. Group membership changes re-derive the group key without any server ' +
      'involvement.',
  },
  {
    name: 'X-Wing · ML-KEM-768',
    role: 'Post-quantum groups',
    spec: 'FIPS 203',
    body:
      'Group keys are hybrid-wrapped with X25519 and ML-KEM-768 together, so a future ' +
      'quantum computer that records today\u2019s group traffic still cannot open it later.',
  },
  {
    name: 'AES-256-GCM',
    role: 'Media and attachments',
    spec: 'NIST SP 800-38D',
    body:
      'Photos, video and files are sealed per file; the file key travels inside the ' +
      'encrypted message itself.',
  },
  {
    name: 'Argon2id + BIP39',
    role: 'Account recovery',
    spec: 'RFC 9106 · BIP-39',
    body:
      'Your recovery phrase is a BIP39 word sequence; your PIN is stretched with ' +
      'Argon2id before it wraps anything. Both are standards, not our own schemes.',
  },
  {
    name: 'HKDF',
    role: 'Call keys',
    spec: 'RFC 5869',
    body:
      'The keys your calls are encrypted with are derived from the same session ' +
      'material as your messages — never transmitted anywhere.',
  },
];

/* Where each piece SITS. Ordered top (what you touch) to bottom (what it all
 * rests on) — see components/CryptoStack.tsx for why this is drawn, not listed. */
const STACK: StackLayer[] = [
  {
    name: 'Voiid app',
    detail: 'chats, calls, the map. Holds no crypto of its own.',
  },
  {
    name: 'e2e-core',
    ours: true,
    detail:
      'one Rust crate: key lifecycle, multi-device fan-out, safety numbers, the media ' +
      'envelope, call-key derivation. This band is the entire custom surface.',
  },
  {
    name: 'vodozemac · OpenMLS',
    detail: 'the ratchet and the group protocol. Published specs, outside implementations.',
  },
  {
    name: 'X-Wing · AES-256-GCM · HKDF · Argon2id',
    detail: 'the primitives themselves. Standardised, and none of them ours.',
  },
];

/* Custom-built, all inside one audited Rust core shared by every platform. */
const BUILT: Built[] = [
  {
    glyph: 'key',
    title: 'Key lifecycle',
    body:
      'Device identity keys, published prekey bundles, and fallback keys that rotate on ' +
      'a schedule and are forgotten once replaced.',
  },
  {
    glyph: 'device',
    title: 'Multi-device fan-out',
    body:
      'One message, sealed separately for each of your devices and each recipient\u2019s — ' +
      'the coordination layer around the ratchet is ours.',
  },
  {
    glyph: 'shield',
    title: 'Safety numbers',
    body:
      'The fingerprint you can compare out loud to verify a contact, built from an ' +
      'iterated hash of both identity keys.',
  },
  {
    glyph: 'note',
    title: 'Media envelope',
    body:
      'How an encrypted file, its key envelope and its ciphertext reference fit together ' +
      'without the server learning either.',
  },
  {
    glyph: 'call',
    title: 'Call key derivation',
    body:
      'Mapping message-session secrets onto the keys a call actually uses, so calls and ' +
      'chats share one root of trust.',
  },
  {
    glyph: 'lock',
    title: 'Relay enforcement',
    body:
      'Our own server refuses to relay anything not shaped like opaque ciphertext — the ' +
      'plumbing physically cannot carry plaintext.',
  },
];

export default function EncryptionPage() {
  return (
    <>
      <Hero
        hue="privacy"
        eyebrow="The stack"
        title={<>Everything we encrypt with, named.</>}
        lede={
          <>
            &ldquo;End-to-end encrypted&rdquo; is a claim about ingredients. Here is the
            full list: the vetted, published cryptography we did not invent, and the
            smaller set of glue we wrote ourselves — with the honest gaps called out at
            the bottom.
          </>
        }
        aside={<LockMotif />}
      />

      {/* ---- where it all sits ------------------------------------------- */}
      <Section
        hue="privacy"
        eyebrow="The shape of it"
        title="A thin layer of ours, on a deep stack of theirs."
        lede={
          <>
            Before the names: this is how much of the stack we actually wrote. One band —
            and it is coordination code, not new cryptography.
          </>
        }
      >
        <CryptoStack
          layers={STACK}
          caption={
            <>
              Every band except one is a published standard with an outside implementation.{' '}
              <strong>The tinted band is the whole of what we wrote</strong>, and even there
              the job is plumbing — deciding which key seals which envelope for which
              device, not inventing a cipher.
            </>
          }
        />
      </Section>

      {/* ---- the vetted primitives ---------------------------------------- */}
      <Section
        hue="privacy"
        tone="raised"
        eyebrow="Not ours to invent"
        title="Vetted primitives we build on."
        lede={
          <>
            Cryptography you write yourself is cryptography you got wrong. Every row below
            is a published, publicly reviewed specification with a maintained
            implementation — pinned by exact name and version in our source tree, and
            named here so you can go and read the spec rather than take our word.
          </>
        }
      >
        <CryptoTable rows={PRIMITIVES} />
      </Section>

      <Section
        hue="privacy"
        eyebrow="Ours"
        title="What we wrote ourselves — all of it in one place."
        lede={
          <>
            The custom part is deliberately small and deliberately centralised: a single
            Rust core (packages/e2e-core) compiled once and bound into every platform,
            so there is exactly one implementation to read and to test. No crypto lives
            in the app code, the API, or the database.
          </>
        }
      >
        <Grid columns={3} gap="md">
          {BUILT.map((b, i) => (
            <Reveal key={b.title} delay={i * 60} className={styles.cell}>
              <div className={styles.built}>
                <span className={styles.builtGlyph} aria-hidden="true">
                  <Glyph name={b.glyph} size={18} />
                </span>
                <h3 className={styles.role}>{b.title}</h3>
                <p className={styles.body}>{b.body}</p>
              </div>
            </Reveal>
          ))}
        </Grid>
      </Section>

      {/* ---- the honest column ---------------------------------------------
          Deliberately NOT the last thing before the CTA as an afterthought: on a
          page whose entire posture is "check us", the list of what we have not
          done is the most credible content on it, so it gets a band of its own
          and a tone that says caveat rather than footnote. */}
      <Section
        hue="privacy"
        tone="inset"
        eyebrow="The honest column"
        title="What we have not done yet."
        lede={
          <>
            Every page like this one is a sales page unless it also says where the gaps
            are. These are ours, stated before anyone has to find them.
          </>
        }
        width="narrow"
      >
        <ul className={styles.honestList}>
          <li>
            <strong>No independent audit yet.</strong> The core carries 93 tests, fuzz
            targets and weekly dependency audits — which is not the same thing as a
            third-party cryptographic review. That review happens before we call this
            production-grade.
          </li>
          <li>
            <strong>Post-quantum is groups-only for now.</strong> A PQ handshake for
            one-to-one chats is written and tested, and switched off until it passes
            external review. Off is a decision, not an accident.
          </li>
          <li>
            <strong>Metadata is not encrypted.</strong> Who talks to whom, and when —
            the same limits described on the{' '}
            <a href="/privacy">privacy page</a>. No scheme here changes that.
          </li>
        </ul>
        <Callout tone="honest" title="Why this list is on the page at all" className={styles.afterHonest}>
          A gap you publish is a gap someone can hold you to. Keeping this list where the
          claims are — rather than in a disclosure buried three clicks away — is the only
          version of &ldquo;check us rather than trust us&rdquo; that means anything.
        </Callout>
      </Section>

      <CTA
        hue="privacy"
        title="Check us rather than trust us."
        lede={
          <>
            The core, its threat model, its known limitations and its test posture are
            all written down. When the repository opens, every claim on this page will
            point at code you can read yourself.
          </>
        }
        actions={
          <ButtonRow align="center">
            <Button href="/privacy" size="lg">
              See what the servers can see
            </Button>
            <Button href="/messaging" variant="secondary" size="lg">
              Back to the product tour
            </Button>
          </ButtonRow>
        }
      />
    </>
  );
}
