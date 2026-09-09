/** Encrypted, atomic snapshot. The non-extractable wrapping key never serializes to JSON.
 * Same-origin malicious JS can still ask WebCrypto to use it: CSP is a separate boundary. */
export class Vault {
  private constructor(private db: IDBDatabase, private key: CryptoKey, private marker: boolean) {}
  static async open(marker = false): Promise<Vault> {
    const db = await new Promise<IDBDatabase>((resolve, reject) => {
      const request = indexedDB.open('voiid-companion', 1);
      request.onupgradeneeded = () => request.result.createObjectStore('vault');
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(new Error('Browser storage is unavailable.'));
      request.onblocked = () => reject(new Error('Close other Voiid tabs and retry.'));
    });
    db.onversionchange = () => db.close();
    const read = db.transaction('vault').objectStore('vault').get('key');
    let key = await new Promise<CryptoKey | undefined>((resolve, reject) => {
      read.onsuccess = () => resolve(read.result); read.onerror = () => reject(read.error);
    });
    if (!key) {
      // This marker contains no credential. It survives a partial IndexedDB eviction.
      if (marker) { db.close(); throw new Error('Browser keys are missing. Remove this browser on your phone, then link again.'); }
      key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
      const tx = db.transaction('vault', 'readwrite', { durability: 'strict' });
      tx.objectStore('vault').put(key, 'key');
      await complete(tx);
    }
    return new Vault(db, key, marker);
  }
  async read<T>(): Promise<T | undefined> {
    const request = this.db.transaction('vault').objectStore('vault').get('snapshot');
    const record = await new Promise<{ iv: Uint8Array; blob: ArrayBuffer } | undefined>((resolve, reject) => {
      request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
    });
    if (!record) {
      if (this.marker) throw new Error('Browser storage was cleared. Link this browser again.');
      return undefined;
    }
    const plaintext = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: record.iv as Uint8Array<ArrayBuffer>, additionalData: new TextEncoder().encode('voiid-companion:v1') }, this.key, record.blob);
    return JSON.parse(new TextDecoder().decode(plaintext)) as T;
  }
  async save(value: unknown): Promise<void> {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const blob = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: new TextEncoder().encode('voiid-companion:v1') }, this.key, new TextEncoder().encode(JSON.stringify(value)));
    const tx = this.db.transaction('vault', 'readwrite', { durability: 'strict' });
    tx.objectStore('vault').put({ iv, blob }, 'snapshot');
    await complete(tx);
  }
  close() { this.db.close(); }
  static async wipe(): Promise<void> {
    await new Promise<void>((resolve, reject) => {
      const request = indexedDB.deleteDatabase('voiid-companion');
      request.onsuccess = () => resolve(); request.onerror = () => reject(request.error);
      request.onblocked = () => reject(new Error('Close other Voiid tabs before clearing this browser.'));
    });
  }
}
function complete(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve(); tx.onabort = tx.onerror = () => reject(new Error('Could not save encrypted data. Free browser storage and reload; your messages have not been acknowledged.'));
  });
}
