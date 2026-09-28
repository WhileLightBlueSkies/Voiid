import { Glyph } from './Glyph';
import styles from './EncryptionJourney.module.css';

const STEPS = [
  { title: 'Sealed on your device', text: 'Your message locks before it leaves your hand.', icon: 'device' as const },
  { title: 'Travels as ciphertext', text: 'Our servers move the sealed packet, never the readable words.', icon: 'lock' as const },
  { title: 'Opens for your person', text: 'Only the intended devices hold the keys to open it.', icon: 'key' as const },
];

export function EncryptionJourney() {
  return (
    <section className={styles.section} aria-label="How Voiid encryption travels">
      <div className={styles.inner}>
        <div className={styles.heading}>
          <p className="eyebrow">Privacy you can see</p>
          <h2>A lock icon should explain something.</h2>
          <p>Here it shows exactly where your private conversation changes state.</p>
        </div>
        <div className={styles.journey}>
          <div className={styles.route} aria-hidden="true">
            <span className={styles.line} />
            <span className={styles.packet} data-encryption-packet><Glyph name="lock" size={14} /></span>
          </div>
          <ol className={styles.steps}>
            {STEPS.map((step, index) => (
              <li key={step.title}>
                <span className={styles.icon}><Glyph name={step.icon} size={22} /></span>
                <span className={styles.number}>0{index + 1}</span>
                <h3>{step.title}</h3>
                <p>{step.text}</p>
              </li>
            ))}
          </ol>
        </div>
      </div>
    </section>
  );
}
