'use client';

import { useState, useCallback } from 'react';
import { PhoneMockup, PhoneAppBar, PhoneAvatar } from './PhoneMockup';
import { Glyph } from './Glyph';
import styles from './InteractivePhoneHero.module.css';

export type ScreenTab = 'chat' | 'calls' | 'map' | 'clips' | 'games';

export function InteractivePhoneHero() {
  const [activeTab, setActiveTab] = useState<ScreenTab>('chat');
  const [callMuted, setCallMuted] = useState(false);
  const [callSpeaker, setCallSpeaker] = useState(true);
  const [mapGhost, setMapGhost] = useState(false);
  const [clipLiked, setClipLiked] = useState(false);
  const [likeCount, setLikeCount] = useState(1420);
  const [handScore, setHandScore] = useState({ user: 4, opp: 2 });
  const [tilt, setTilt] = useState({ x: 0, y: 0 });
  const [isHovered, setIsHovered] = useState(false);

  const handleMouseMove = useCallback((e: React.MouseEvent<HTMLDivElement>) => {
    const rect = e.currentTarget.getBoundingClientRect();
    const x = (e.clientX - rect.left) / rect.width - 0.5;
    const y = (e.clientY - rect.top) / rect.height - 0.5;
    setTilt({ x: Math.round(x * 14 * 10) / 10, y: Math.round(-y * 14 * 10) / 10 });
  }, []);

  const handleMouseLeave = useCallback(() => {
    setIsHovered(false);
    setTilt({ x: 0, y: 0 });
  }, []);

  const handleMouseEnter = useCallback(() => {
    setIsHovered(true);
  }, []);

  return (
    <div className={styles.wrapper}>
      {/* Outer Tab Selector floating above the phone */}
      <nav className={styles.tabSelector} aria-label="Interactive demo surfaces">
        {(['chat', 'calls', 'map', 'clips', 'games'] as const).map((tab) => (
          <button
            key={tab}
            type="button"
            className={[styles.tabButton, activeTab === tab ? styles.tabActive : ''].join(' ')}
            onClick={() => setActiveTab(tab)}
            aria-pressed={activeTab === tab}
          >
            <Glyph name={tab === 'chat' ? 'chat' : tab === 'calls' ? 'call' : tab} size={15} />
            <span>{tab === 'chat' ? 'Chats' : tab.charAt(0).toUpperCase() + tab.slice(1)}</span>
          </button>
        ))}
      </nav>

      {/* 3D Stage with Tilt & Orbiting Badges */}
      <div
        className={styles.stageWrap}
        onMouseMove={handleMouseMove}
        onMouseEnter={handleMouseEnter}
        onMouseLeave={handleMouseLeave}
        style={{
          transform: `perspective(1200px) rotateX(${tilt.y}deg) rotateY(${tilt.x}deg)`,
          transition: isHovered
            ? 'transform 80ms cubic-bezier(0.1, 0.9, 0.2, 1)'
            : 'transform 450ms cubic-bezier(0.16, 1, 0.3, 1)',
        }}
      >
        {/* Floating Innovation Pill 1: E2EE */}
        <div className={[styles.floatingBadge, styles.badgeTopLeft].join(' ')}>
          <span className={styles.badgeDot} />
          <span className={styles.badgeText}>Hardware-Sealed E2EE</span>
        </div>

        {/* Floating Innovation Pill 2: 3-Column Native Grid */}
        <div className={[styles.floatingBadge, styles.badgeTopRight].join(' ')}>
          <span className={styles.badgeIcon}>⚡</span>
          <span className={styles.badgeText}>3-Column Visual Grid</span>
        </div>

        {/* Floating Innovation Pill 3: Authentic Native App */}
        <div className={[styles.floatingBadge, styles.badgeBottomRight].join(' ')}>
          <span className={styles.badgeIcon}>🇮🇳</span>
          <span className={styles.badgeText}>Running on iOS 18</span>
        </div>

        {/* The Phone Hardware Mockup */}
        <PhoneMockup
          hue={activeTab}
          size="lg"
          tilt="none"
          fullBleed={activeTab === 'chat'}
          label={`Live interactive ${activeTab} preview`}
        >
          {/* TAB 1: REAL LIVE CHATS SCREENSHOT (From actual iPhone 15) */}
          {activeTab === 'chat' && (
            <div className={styles.realScreenWrapper}>
              <img
                src="/screens/chats_real.png"
                alt="Actual Voiid iOS app interface showing encrypted chats grid"
                className={styles.realScreenshot}
                draggable={false}
              />
              {/* Dynamic glass specular glare responsive to tilt */}
              <div
                className={styles.glassReflection}
                style={{
                  background: `linear-gradient(${125 + tilt.x * 3}deg, rgba(255,255,255,0.18) 0%, rgba(255,255,255,0.04) 40%, transparent 60%)`,
                }}
                aria-hidden="true"
              />
            </div>
          )}

          {/* TAB 2: CALLS */}
          {activeTab === 'calls' && (
            <div className={styles.callContainer}>
              <PhoneAppBar title="Encrypted Call" subtitle="SRTP · AES-256-GCM" />
              <div className={styles.callBody}>
                <div className={styles.callAvatarWrap}>
                  <div className={styles.callPulseRing} />
                  <div className={styles.callAvatar}>
                    <PhoneAvatar initials="N" size={72} seed={3} />
                  </div>
                </div>
                <h4 className={styles.callCaller}>Nehal</h4>
                <p className={styles.callTimer}>04:18</p>
                <div className={styles.callWaveform}>
                  {[40, 75, 55, 90, 60, 85, 45, 95, 70, 50, 80, 65].map((h, i) => (
                    <span
                      key={i}
                      className={styles.waveBar}
                      style={{
                        height: `${h}%`,
                        animationDelay: `${i * 0.08}s`,
                      }}
                    />
                  ))}
                </div>
                <span className={styles.callBadge}>
                  <Glyph name="lock" size={12} />
                  Frame-level E2EE · No server listen
                </span>
              </div>
              <div className={styles.callControlsRow}>
                <button
                  type="button"
                  className={[styles.callBtn, callMuted ? styles.callBtnActive : ''].join(' ')}
                  onClick={() => setCallMuted(!callMuted)}
                  title={callMuted ? 'Unmute' : 'Mute'}
                >
                  <Glyph name="eye-off" size={18} />
                </button>
                <button
                  type="button"
                  className={[styles.callBtn, callSpeaker ? styles.callBtnActive : ''].join(' ')}
                  onClick={() => setCallSpeaker(!callSpeaker)}
                  title="Speakerphone"
                >
                  <Glyph name="device" size={18} />
                </button>
                <button
                  type="button"
                  className={styles.callBtnEnd}
                  onClick={() => setActiveTab('chat')}
                  title="End Call"
                >
                  <Glyph name="call" size={18} />
                </button>
              </div>
            </div>
          )}

          {/* TAB 3: MAP */}
          {activeTab === 'map' && (
            <div className={styles.mapContainer}>
              <PhoneAppBar
                title="Live Map"
                subtitle={mapGhost ? 'Ghost Mode Active' : '2 Friends in Bengaluru'}
                trailing={
                  <button
                    type="button"
                    className={[styles.ghostToggle, mapGhost ? styles.ghostOn : ''].join(' ')}
                    onClick={() => setMapGhost(!mapGhost)}
                    title="Toggle Ghost Mode"
                  >
                    <Glyph name={mapGhost ? 'eye-off' : 'broadcast'} size={15} />
                  </button>
                }
              />
              <div className={[styles.mapViewport, mapGhost ? styles.mapDark : ''].join(' ')}>
                <div className={styles.mapGridLines} />
                {!mapGhost && (
                  <>
                    <div className={styles.mapPinSelf} style={{ top: '48%', left: '46%' }}>
                      <div className={styles.mapPulse} />
                      <div className={styles.mapPinDot}>You</div>
                    </div>
                    <div className={styles.mapPinFriend} style={{ top: '34%', left: '68%' }}>
                      <div className={styles.mapPinLabel}>Aditi · 12m</div>
                    </div>
                  </>
                )}
                {mapGhost && (
                  <div className={styles.ghostNotice}>
                    <Glyph name="eye-off" size={24} />
                    <span>Ghost Mode: Session key rotated. You are invisible.</span>
                  </div>
                )}
                <div className={styles.mapFooterBanner}>
                  <Glyph name="lock" size={11} />
                  <span>Auto-expiring shares · Never written to DB</span>
                </div>
              </div>
            </div>
          )}

          {/* TAB 4: CLIPS */}
          {activeTab === 'clips' && (
            <div className={styles.clipsContainer}>
              <div className={styles.clipsVideoSim}>
                <div className={styles.clipsGradientOverlay} />
                <div className={styles.clipsTopBar}>
                  <span className={styles.clipsScopeActive}>Explore</span>
                  <span className={styles.clipsScopeInactive}>Following</span>
                </div>

                <div className={styles.clipsFloatingRight}>
                  <button
                    type="button"
                    className={[styles.clipActionBtn, clipLiked ? styles.clipLiked : ''].join(' ')}
                    onClick={() => {
                      setClipLiked(!clipLiked);
                      setLikeCount((c) => (clipLiked ? c - 1 : c + 1));
                    }}
                  >
                    <span className={styles.clipHeartIcon}>♥</span>
                    <span className={styles.clipActionCount}>{likeCount}</span>
                  </button>
                  <div className={styles.clipActionBtn}>
                    <Glyph name="chat" size={18} />
                    <span className={styles.clipActionCount}>84</span>
                  </div>
                  <div className={styles.clipActionBtn}>
                    <Glyph name="sparkle" size={18} />
                    <span className={styles.clipActionCount}>Puppy</span>
                  </div>
                </div>

                <div className={styles.clipsBottomMeta}>
                  <p className={styles.clipAuthor}>@priyanshu</p>
                  <p className={styles.clipCaption}>Testing out the new face tracking filter in Voiid Clips! 🐶✨</p>
                  <div className={styles.clipAudioTrack}>
                    <span className={styles.musicBars}>
                      <span />
                      <span />
                      <span />
                    </span>
                    <span>Original Audio · Priyanshu</span>
                  </div>
                </div>
              </div>
            </div>
          )}

          {/* TAB 5: GAMES */}
          {activeTab === 'games' && (
            <div className={styles.gamesContainer}>
              <PhoneAppBar title="Hand Cricket" subtitle="Match #8491 · In Progress" />
              <div className={styles.gameBoard}>
                <div className={styles.scoreboard}>
                  <div className={styles.scoreCol}>
                    <span className={styles.scoreName}>You</span>
                    <span className={styles.scoreNum}>{handScore.user}</span>
                    <span className={styles.scoreRole}>Batting</span>
                  </div>
                  <div className={styles.vsBadge}>VS</div>
                  <div className={styles.scoreCol}>
                    <span className={styles.scoreName}>Aditi</span>
                    <span className={styles.scoreNum}>{handScore.opp}</span>
                    <span className={styles.scoreRole}>Bowling</span>
                  </div>
                </div>

                <div className={styles.gameActionPrompt}>
                  Pick your run (1–6):
                </div>
                <div className={styles.gameRunPicker}>
                  {[1, 2, 3, 4, 5, 6].map((run) => (
                    <button
                      key={run}
                      type="button"
                      className={styles.runPickBtn}
                      onClick={() => {
                        const opp = Math.floor(Math.random() * 6) + 1;
                        setHandScore({ user: run, opp });
                      }}
                    >
                      {run}
                    </button>
                  ))}
                </div>
                <p className={styles.gameRefereeNote}>
                  <Glyph name="shield" size={12} />
                  Server validated moves to prevent client modification.
                </p>
              </div>
            </div>
          )}
        </PhoneMockup>
      </div>
    </div>
  );
}
