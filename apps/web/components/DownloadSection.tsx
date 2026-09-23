import { STORE_LINKS } from '../lib/downloads';
import { Glyph } from './Glyph';
import styles from './DownloadSection.module.css';

function StoreBadge({ store, href }: { store: 'App Store' | 'Google Play'; href: string | null }) {
  const content = <><span className={styles.storeIcon} aria-hidden="true">{store === 'App Store' ? 'A' : '▶'}</span><span><small>Download on the</small><b>{store}</b></span>{href ? <Glyph name="arrow-right" size={16}/> : <em>Coming soon</em>}</>;
  return href ? <a className={styles.store} href={href} target="_blank" rel="noopener noreferrer" aria-label={`Download Voiid on the ${store}`}>{content}</a> : <div className={`${styles.store} ${styles.pending}`}>{content}</div>;
}

export function DownloadSection() {
  return <section id="download" className={styles.section} aria-labelledby="download-title"><div className={styles.inner}>
    <div className={styles.copy}><p className="eyebrow">Voiid for your phone</p><h2 id="download-title">One place for the people who matter.</h2><p>Voiid is preparing for iOS and Android. The official links will appear here as soon as each store listing is live.</p><div className={styles.stores}><StoreBadge store="App Store" href={STORE_LINKS.appStore}/><StoreBadge store="Google Play" href={STORE_LINKS.playStore}/></div></div>
    <div className={styles.qr}><span className={styles.cornerOne}/><span className={styles.cornerTwo}/><span className={styles.cornerThree}/><span className={styles.qrMark}><Glyph name="device" size={28}/></span><strong>Scan to download</strong><p>QR code will appear here</p></div>
  </div></section>;
}
