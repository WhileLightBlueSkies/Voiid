import styles from './CryptoTable.module.css';

/**
 * The vetted-primitives table.
 *
 * See the module CSS for why this is a table rather than the card grid it
 * replaced. The `spec` column is the load-bearing one: naming the RFC or the
 * maintaining body is what makes a claim checkable, and checkable is the whole
 * posture of this page.
 */

export type PrimitiveRow = {
  name: string;
  role: string;
  /** RFC number or maintaining body — whatever a reader would go and look up. */
  spec: string;
  body: string;
};

export function CryptoTable({ rows }: { rows: PrimitiveRow[] }) {
  return (
    <>
      <div className={styles.wrap}>
        <table className={styles.table}>
          <thead>
            <tr>
              <th scope="col">Primitive</th>
              <th scope="col">Used for</th>
              <th scope="col">Specification</th>
              <th scope="col">What it does</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.name}>
                {/* Row header: the primitive names the row it heads. */}
                <th scope="row" className={styles.name}>
                  {r.name}
                </th>
                <td className={styles.role}>{r.role}</td>
                <td>
                  <span className={styles.spec}>{r.spec}</span>
                </td>
                <td className={styles.desc}>{r.body}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className={styles.scrollHint}>Scroll the table sideways to see every column.</p>
    </>
  );
}
