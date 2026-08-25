import Link from 'next/link';
import { FEATURE_NAV } from '../lib/nav';
import { CONTACT, CONTACT_INCOMPLETE, type ContactField } from '../lib/contact';
import { Wordmark } from './Wordmark';
import { Logomark } from './Logomark';
import { Glyph } from './Glyph';
import styles from './SiteFooter.module.css';

/**
 * The footer, and the site's legal surface.
 *
 * It carries the DPDP grievance-officer block, which is not decoration: the Act
 * (s.13) and IT Rules 2021 (Rule 3(2)) both require a published, named contact. The
 * fields are placeholders today and are RENDERED AS PLACEHOLDERS rather than filled
 * with plausible-looking text — see lib/contact.ts for why that matters.
 */

function Field({ field }: { field: ContactField }) {
  if (field.placeholder) {
    return <span className={styles.pending}>{field.value}</span>;
  }
  return field.href ? (
    <a href={field.href}>{field.value}</a>
  ) : (
    <span>{field.value}</span>
  );
}

export function SiteFooter() {
  const year = 2026;

  return (
    <footer className={styles.footer}>
      {/*
        The closing statement (Ft5). A footer's first job is to CLOSE the page,
        not to restate its sitemap — the nav already did that. This is the one
        line the site is actually arguing, set large enough to be read as a
        parting thought rather than as small print.

        The reference-and-legal columns still follow it. A Statement footer
        normally REPLACES a link sitemap, but this one carries the DPDP
        grievance block, which is a statutory disclosure (Act s.13, IT Rules
        Rule 3(2)) — dropping it to satisfy a layout would be a bad trade. So
        the statement leads and the obligations sit beneath it.
      */}
      <p className={styles.statement}>
        We would rather tell you what we can see than promise you we are blind.
      </p>

      <div className={styles.inner}>
        <div className={styles.brandCol}>
          {/* The lockup: mark + wordmark on one row. brandCol is a column, so
              the pair needs its own row wrapper or they stack. */}
          <span className={styles.lockup}>
            <Logomark size={25} idPrefix="footer" />
            <Wordmark size={24} />
          </span>
          <p className={styles.tagline}>
            One app for chat, calls, the map, clips and games. Built in India.
          </p>
          <p className={styles.built}>
            <Glyph name="globe" size={15} />
            Made in India · available worldwide
          </p>
        </div>

        <nav className={styles.col} aria-labelledby="footer-product">
          <h2 id="footer-product" className={styles.colTitle}>
            Product
          </h2>
          <ul className={styles.list}>
            {FEATURE_NAV.map((item) => (
              <li key={item.href}>
                <Link href={item.href}>{item.label}</Link>
              </li>
            ))}
          </ul>
        </nav>

        <div className={styles.col}>
          <h2 className={styles.colTitle}>Contact</h2>
          <ul className={styles.list}>
            <li>
              General: <Field field={CONTACT.general} />
            </li>
            <li>
              Security reports: <Field field={CONTACT.security} />
            </li>
          </ul>
        </div>

        {/* ---- DPDP / IT Rules grievance block ------------------------------ */}
        <section className={styles.grievance} aria-labelledby="footer-grievance">
          <h2 id="footer-grievance" className={styles.colTitle}>
            Grievance Officer
          </h2>
          <p className={styles.grievanceIntro}>
            Required under the Digital Personal Data Protection Act, 2023 (s.13) and the
            IT Rules, 2021 (Rule 3(2)). Write here about your personal data, or to
            complain about content.
          </p>
          <dl className={styles.dl}>
            <dt>Name</dt>
            <dd>
              <Field field={CONTACT.grievance.name} />
            </dd>
            <dt>Email</dt>
            <dd>
              <Field field={CONTACT.grievance.email} />
            </dd>
            <dt>Address</dt>
            <dd>
              <Field field={CONTACT.grievance.address} />
            </dd>
            <dt>Response time</dt>
            <dd>
              <Field field={CONTACT.grievance.responseWindow} />
            </dd>
          </dl>
          {CONTACT_INCOMPLETE ? (
            <p className={styles.notice}>
              These details are not yet published. We would rather show you an empty
              field than an address nobody is reading.
            </p>
          ) : null}
        </section>
      </div>

      <div className={styles.baseline}>
        <p>
          © {year} <Field field={CONTACT.entity} />. Voiid.
        </p>
        <ul className={styles.legal}>
          <li>
            <Link href="/privacy">Privacy</Link>
          </li>
        </ul>
      </div>
    </footer>
  );
}
