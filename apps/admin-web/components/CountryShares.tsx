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
      {/* Compact ROWS, not cards. This panel occupies two grid cells beside a chart, and
          six bordered boxes with 22px numerals overwhelmed the slot — the question is a
          ranking, and a ranking reads down a column faster than across a grid. */}
      <div style={{ display: 'grid', gap: 9 }}>
        {top.map((c, i) => (
          <div key={c.code} className="row" style={{ gap: 10 }}>
            <span style={{ fontSize: 14, lineHeight: 1, width: 18 }}>{flag(c.code)}</span>

            <span
              style={{
                fontSize: 13, fontWeight: 500, width: 96, flex: '0 0 96px',
                overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
              }}
              title={`${c.name} · ${c.users} ${c.users === 1 ? 'account' : 'accounts'}`}
            >
              {c.name}
            </span>

            <div style={{ flex: 1, height: 5, background: 'var(--surface-3)',
                          borderRadius: 999, overflow: 'hidden', minWidth: 0 }}>
              <div style={{
                width: `${c.share}%`, height: '100%', borderRadius: 999,
                background: PALETTE[i % PALETTE.length],
                // A non-zero share must never render as an invisible sliver: reading as
                // nothing at all is a different fact from being small.
                minWidth: c.users > 0 ? 3 : 0,
              }} />
            </div>

            <span className="mono" style={{ fontSize: 12, fontWeight: 600,
                                            width: 44, textAlign: 'right' }}>
              {c.share}%
            </span>
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
