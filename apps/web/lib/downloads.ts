export const STORE_LINKS: {
  appStore: string | null;
  playStore: string | null;
} = {
  appStore: null,
  playStore: null,
};

export function hasStoreLinks(): boolean {
  return Boolean(STORE_LINKS.appStore || STORE_LINKS.playStore);
}
