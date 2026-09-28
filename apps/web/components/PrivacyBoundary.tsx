import Link from 'next/link';
import { Glyph } from './Glyph';
import styles from './PrivacyBoundary.module.css';

export function PrivacyBoundary({ encrypted, serverReadable }: { encrypted: string[]; serverReadable: string[] }) {
  return (
    <section className={styles.section} aria-labelledby="privacy-boundary-title"><div className={styles.inner}>
      <div className={styles.copy}><p className="eyebrow">No tiny-print privacy</p><h2 id="privacy-boundary-title">Private is a boundary—not a blanket promise.</h2><p>We show where encryption applies and where a public or refereed feature needs the server.</p><div className={styles.links}><Link href="/privacy/">Read the privacy breakdown</Link><Link href="/encryption/">See the encryption stack</Link></div></div>
      <div className={styles.ledger}>
        <article><span className={styles.badge}><Glyph name="lock" size={18}/></span><h3>End-to-end encrypted</h3><ul>{encrypted.map(item=><li key={item}><Glyph name="check" size={14}/><span>{item}</span></li>)}</ul></article>
        <article><span className={`${styles.badge} ${styles.open}`}><Glyph name="broadcast" size={18}/></span><h3>Server-readable by design</h3><ul>{serverReadable.map(item=><li key={item}><Glyph name="broadcast" size={14}/><span>{item}</span></li>)}</ul></article>
      </div>
    </div></section>
  );
}
