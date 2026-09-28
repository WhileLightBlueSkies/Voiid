import { Glyph } from './Glyph';
import { PhoneFrame } from './PhoneFrame';
import styles from './DeviceScene.module.css';

/**
 * The hero product shot: two devices, one showing a thread and one showing the
 * encrypted call that thread turned into.
 *
 * Both are `PhoneFrame`, so this is the same physical phone as the interactive
 * tour — a visitor who opens the tour recognises the hardware they were just
 * looking at. The interfaces are static here on purpose: this is a picture, and
 * it is marked up as one, with a single accessible name per device and no
 * reachable controls.
 */
export function DeviceScene() {
  return (
    <div className={styles.scene}>
      <div className={styles.glow} aria-hidden="true" />

      <PhoneFrame
        className={`${styles.phone} ${styles.back}`}
        width="min(13.5rem, 40vw)"
        time="9:41"
        chrome="light"
        label="A Voiid voice call in progress, marked end-to-end encrypted"
      >
        <div className={styles.call}>
          <span className={styles.callAvatar}>N</span>
          <strong className={styles.callName}>Nehal</strong>
          <span className={styles.callMeta}>04:12</span>
          <span className={styles.callLock}>
            <Glyph name="lock" size={11} /> End-to-end encrypted
          </span>
          <span className={styles.callControls}>
            <span><Glyph name="device" size={13} /></span>
            <span><Glyph name="eye-off" size={13} /></span>
            <span className={styles.callEnd}><Glyph name="call" size={13} /></span>
          </span>
        </div>
      </PhoneFrame>

      <PhoneFrame
        className={`${styles.phone} ${styles.front}`}
        width="min(15.5rem, 46vw)"
        time="9:41"
        label="A Voiid chat with Aditi showing an encrypted message and a live location share"
      >
        <div className={styles.chat}>
          <header className={styles.chatBar}>
            <span className={styles.avatar}>A</span>
            <span className={styles.who}>
              <strong>Aditi</strong>
              <small><Glyph name="lock" size={9} /> end-to-end encrypted</small>
            </span>
            <span className={styles.chatIcons}>
              <Glyph name="call" size={13} />
            </span>
          </header>

          <div className={styles.thread}>
            <span className={styles.notice}>
              <Glyph name="lock" size={10} />
              Messages in this chat are end-to-end encrypted.
            </span>
            <span className={styles.day}>Today</span>
            <span className={`${styles.bubble} ${styles.received}`}>Reached the station 😄</span>
            <span className={`${styles.bubble} ${styles.sent}`}>
              Ten minutes away
              <em className={styles.ticks}>✓✓</em>
            </span>
            <span className={`${styles.bubble} ${styles.received}`}>Made it. Share your location?</span>
            <span className={`${styles.bubble} ${styles.sent}`}>
              For the next hour
              <em className={styles.ticks}>✓✓</em>
            </span>
            <span className={styles.locationCard}>
              <span className={styles.locationMap} aria-hidden="true">
                <span className={styles.locationPin} />
              </span>
              <span className={styles.locationText}>
                <strong>Live location</strong>
                <small>58 min left · only Aditi</small>
              </span>
            </span>
          </div>

          <div className={styles.composer}>
            <span className={styles.composerField}>Message</span>
            <span className={styles.send}><Glyph name="arrow-right" size={12} /></span>
          </div>
        </div>
      </PhoneFrame>

      <p className={styles.seal} aria-hidden="true">
        <span className={styles.sealRing} />
        <Glyph name="lock" size={15} />
        Sealed on this device
      </p>
    </div>
  );
}
