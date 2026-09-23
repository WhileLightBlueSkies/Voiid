// Pure name comparison for host KYC — no I/O, so it can be tested on its own.

/**
 * Do two names belong to the same person? Initials and order vary between PAN and Aadhaar
 * ("R. SHARMA" vs "Rahul Sharma"), so: every full word of the shorter name appears in the
 * longer, and an initial matches any word starting with it. A guide for the reviewer, never
 * a decision on its own.
 */
export function namesMatch(a: string, b: string): boolean {
  const words = (s: string) => s.toUpperCase().replace(/[^A-Z ]/g, ' ').split(/\s+/).filter(Boolean);
  let [short, long] = [words(a), words(b)];
  if (short.length > long.length) [short, long] = [long, short];
  if (short.length === 0) return false;
  return short.every((w) => w.length === 1 ? long.some((l) => l.startsWith(w)) : long.includes(w));
}
