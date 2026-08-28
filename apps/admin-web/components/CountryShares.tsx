'use client';

//
// Where accounts registered, as ranked cards.
//
// No map. A world map spends most of its area on ocean and on countries with no accounts,
// and the question here — which countries, what share — is answered faster by a ranked list
// than by hunting for a coloured dot. It also sidesteps a real problem: a map of
// dialling-prefix data invites the reading "our users are HERE", which the data cannot
// support.
//

export type CountryShare = { code: string; name: string; users: number; share: number };

const PALETTE = ['var(--accent)', '#7c6cf0', '#3b82f6', '#2fa36b', '#f6821f', '#c86bd8'];

/** Regional-indicator flag from an ISO alpha-2 code. */
function flag(code: string): string {
  // NANP and UNKNOWN are not countries and have no flag; a globe is honest about that.
  if (!/^[A-Z]{2}$/.test(code)) return '🌐';
  return String.fromCodePoint(...[...code].map((c) => 0x1f1a5 + c.charCodeAt(0)));
}

export function CountryShares({ countries, limit = 6 }: {
  countries: CountryShare[]; limit?: number;
}) {
  const top = countries.slice(0, limit);
  const rest = countries.slice(limit);
  // The tail is SUMMED rather than dropped. A list of six that silently omits the seventh
  // implies the six are everything, and the shares would not add to 100.
  const restUsers = rest.reduce((n, c) => n + c.users, 0);
  const restShare = Math.round(rest.reduce((n, c) => n + c.share, 0) * 10) / 10;

  return (
    <div>
      <div
        style={{
          display: 'grid', gap: 12,
          gridTemplateColumns: 'repeat(auto-fit, minmax(190px, 1fr))',
        }}
      >
        {top.map((c, i) => (
          <div
            key={c.code}
            style={{
              background: 'var(--surface-2)', border: '1px solid var(--border)',
              borderRadius: 'var(--radius)', padding: '12px 14px',
            }}
          >
            <div className="row" style={{ gap: 8, marginBottom: 8 }}>
              <span style={{ fontSize: 17, lineHeight: 1 }}>{flag(c.code)}</span>
              <span style={{ fontSize: 13, fontWeight: 600, minWidth: 0,
                             overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {c.name}
              </span>
            </div>

            <div className="row" style={{ gap: 8, alignItems: 'baseline' }}>
              <span className="mono" style={{ fontSize: 22, fontWeight: 650, letterSpacing: '-0.02em' }}>
                {c.share}%
              </span>
              <span className="mute" style={{ fontSize: 12 }}>
                {c.users} {c.users === 1 ? 'account' : 'accounts'}
              </span>
            </div>

            <div style={{ height: 4, background: 'var(--surface-3)', borderRadius: 999,
                          overflow: 'hidden', marginTop: 9 }}>
              <div style={{
                width: `${c.share}%`, height: '100%', borderRadius: 999,
                background: PALETTE[i % PALETTE.length],
                // A non-zero share must never render as an invisible sliver: reading as
                // nothing at all is a different fact from being small.
                minWidth: c.users > 0 ? 3 : 0,
              }} />
            </div>
          </div>
        ))}
      </div>

      {rest.length > 0 && (
        <p className="mute" style={{ fontSize: 12, margin: '12px 0 0' }}>
          {rest.length} more {rest.length === 1 ? 'country' : 'countries'} · {restUsers}{' '}
          {restUsers === 1 ? 'account' : 'accounts'} · {restShare}%
        </p>
      )}
    </div>
  );
}
