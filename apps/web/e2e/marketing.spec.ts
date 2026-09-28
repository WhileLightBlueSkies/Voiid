import { expect, test } from '@playwright/test';

test.describe('public marketing website', () => {
  test('home exposes canonical metadata and software structured data', async ({ page }) => {
    await page.goto('/');

    await expect(page).toHaveTitle(/private messaging.*Voiid/i);
    await expect(page.locator('link[rel="canonical"]')).toHaveAttribute(
      'href',
      /^https:\/\//,
    );
    const structuredData = await page
      .locator('script[type="application/ld+json"]')
      .textContent();
    expect(structuredData).toContain('SoftwareApplication');
  });

  test('missing store URLs never render broken links', async ({ page }) => {
    await page.goto('/');

    await expect(page.getByText('Coming soon', { exact: true })).toHaveCount(2);
    await expect(page.locator('a[href="#"]')).toHaveCount(0);
  });

  test('theme starts light and restores an explicit dark choice', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
    await page.getByRole('button', { name: 'Switch to dark mode' }).click();
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');

    await page.reload();
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
    await expect(page.getByRole('button', { name: 'Switch to light mode' })).toBeVisible();
  });

  test('mobile navigation closes after following a feature link', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 812 });
    await page.goto('/');

    const menu = page.getByRole('button', { name: 'Menu' });
    await menu.click();
    await expect(menu).toHaveAttribute('aria-expanded', 'true');
    await page.getByRole('link', { name: /Messaging/ }).first().click();
    await expect(page).toHaveURL(/\/messaging\/$/);
    await expect(page.getByRole('button', { name: 'Menu' })).toHaveAttribute(
      'aria-expanded',
      'false',
    );
  });

  test('phone navigation shows the product destinations without another disclosure', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 812 });
    await page.goto('/');
    await page.getByRole('button', { name: 'Menu' }).click();

    const nav = page.getByRole('navigation', { name: 'Main' });
    for (const name of ['Messaging', 'Calls', 'Map', 'Clips', 'Games']) {
      await expect(nav.getByRole('link', { name: new RegExp(name) })).toBeVisible();
    }
  });

  test('phone page has readable copy and no sideways scroll', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 812 });
    await page.goto('/');

    const sizes = await page.evaluate(() => ({
      heading: parseFloat(getComputedStyle(document.querySelector('h1')!).fontSize),
      featureCopy: parseFloat(getComputedStyle(document.querySelector('#features a p')!).fontSize),
      pageWidth: document.documentElement.scrollWidth,
      viewportWidth: window.innerWidth,
    }));
    expect(sizes.heading).toBeGreaterThanOrEqual(46);
    expect(sizes.featureCopy).toBeGreaterThanOrEqual(16);
    expect(sizes.pageWidth).toBeLessThanOrEqual(sizes.viewportWidth);
  });

  test('homepage leads with one clear product story', async ({ page }) => {
    await page.goto('/');

    await expect(page.getByRole('heading', { level: 1 })).toHaveCount(1);
    await expect(page.getByRole('heading', { level: 1 })).toContainText(
      'Stay close. Keep control.',
    );
    await expect(page.getByRole('button', { name: 'Go through the app' })).toBeVisible();
    await expect(page.getByRole('link', { name: 'Explore features' })).toBeVisible();
  });

  test('encryption journey stays meaningful without motion', async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await page.goto('/');

    const journey = page.getByRole('region', { name: 'How Voiid encryption travels' });
    await expect(journey.getByText('Sealed on your device')).toBeVisible();
    await expect(journey.getByText('Travels as ciphertext')).toBeVisible();
    await expect(journey.getByText('Opens for your person')).toBeVisible();
    await expect(page.locator('[data-encryption-packet]')).toHaveCSS('animation-name', 'none');
  });

  test('app sandbox opens, closes and restores focus', async ({ page }) => {
    await page.goto('/');

    const launcher = page.getByRole('button', { name: 'Go through the app' });
    await launcher.click();
    const dialog = page.getByRole('dialog', { name: 'Explore Voiid' });
    await expect(dialog).toBeVisible();
    await expect(page.locator('body')).toHaveAttribute('data-sandbox-open', 'true');
    await expect(dialog.getByRole('button', { name: 'Close app tour' })).toBeFocused();

    await page.keyboard.press('Escape');
    await expect(dialog).toBeHidden();
    await expect(page.locator('body')).not.toHaveAttribute('data-sandbox-open', 'true');
    await expect(launcher).toBeFocused();
  });

  test('app sandbox drops its screen transitions under reduced motion', async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await page.goto('/');
    await page.getByRole('button', { name: 'Go through the app' }).click();
    const dialog = page.getByRole('dialog', { name: 'Explore Voiid' });

    // The screen still changes — it just does not slide there.
    await dialog.getByRole('button', { name: /Aditi/ }).first().click();
    await expect(dialog.getByRole('heading', { name: 'Aditi' })).toBeVisible();
    await expect(page.locator('[data-direction]')).toHaveCSS('animation-name', 'none');
  });

  test('app sandbox runs as an app, not a slideshow', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Go through the app' }).click();
    const dialog = page.getByRole('dialog', { name: 'Explore Voiid' });

    // Navigation is INSIDE the phone: a tab bar at the root, a back stack once
    // you open something. The tab bar must disappear on a pushed screen.
    await expect(dialog.getByRole('navigation', { name: 'App tabs' })).toBeVisible();
    await dialog.getByRole('button', { name: /Aditi/ }).first().click();
    await expect(dialog.getByRole('navigation', { name: 'App tabs' })).toBeHidden();

    // A real composer with a real reply.
    await dialog.getByRole('textbox', { name: 'Message Aditi' }).fill('On my way');
    await dialog.getByRole('button', { name: 'Send message' }).click();
    await expect(dialog.getByText('On my way')).toBeVisible();
    await expect(dialog.getByText('Got it — see you at the gate 👋')).toBeVisible();

    // Location sharing happens in the thread and posts a card.
    await dialog.getByRole('button', { name: /Share location/ }).click();
    await dialog.getByRole('button', { name: '1 hour' }).click();
    await expect(dialog.getByText('60 min · only this chat')).toBeVisible();

    // A call is pushed from the chat and hanging up returns to it with a receipt.
    await dialog.getByRole('button', { name: /voice call with Aditi/ }).click();
    await expect(dialog.getByRole('timer')).toBeVisible();
    await dialog.getByRole('button', { name: 'Mute your microphone' }).click();
    await expect(dialog.getByText('Your microphone is muted.')).toBeVisible();
    await dialog.getByRole('button', { name: 'End the call' }).click();
    await expect(dialog.getByText(/Encrypted call ended/)).toBeVisible();

    // Back returns to the chat list and the tab bar comes back with it.
    await dialog.getByRole('button', { name: 'Back', exact: true }).click();
    await expect(dialog.getByRole('navigation', { name: 'App tabs' })).toBeVisible();
  });

  test('app sandbox surfaces work and reset', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Go through the app' }).click();
    const dialog = page.getByRole('dialog', { name: 'Explore Voiid' });
    const tabs = dialog.getByRole('navigation', { name: 'App tabs' });

    await tabs.getByRole('button', { name: 'Map' }).click();
    await dialog.getByRole('button', { name: '1 hour' }).click();
    await dialog.getByRole('button', { name: 'Start sharing' }).click();
    await expect(dialog.getByText(/Sharing your live location for 1 hour/)).toBeVisible();

    await tabs.getByRole('button', { name: 'Clips' }).click();
    await dialog.getByRole('button', { name: /^Like the clip/ }).click();
    await expect(dialog.getByRole('button', { name: /^Unlike the clip/ })).toBeVisible();

    await tabs.getByRole('button', { name: 'Games' }).click();
    await dialog.getByRole('button', { name: /Hand Cricket/ }).first().click();
    await dialog.getByRole('button', { name: 'Play 3' }).click();
    await expect(dialog.getByRole('status').first()).toBeVisible();

    await dialog.getByRole('button', { name: 'Reset tour' }).click();
    await expect(dialog.getByRole('heading', { name: 'Chats' })).toBeVisible();
    await expect(dialog.getByText('On my way')).toBeHidden();
  });

  test('app sandbox offers exactly the four games the site documents', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Go through the app' }).click();
    const dialog = page.getByRole('dialog', { name: 'Explore Voiid' });
    await dialog.getByRole('navigation', { name: 'App tabs' }).getByRole('button', { name: 'Games' }).click();

    // Four games are seeded server-side and /games says so. A fifth here would be
    // the site advertising something a visitor cannot find.
    const catalogue = ['Tic Tac Toe', 'Rock Paper Scissors', 'Hand Cricket', 'Snake'];
    for (const name of catalogue) {
      await expect(dialog.getByRole('button', { name: new RegExp(name) }).first()).toBeVisible();
    }

    // And each one actually reaches a playable control, not a dead end.
    await dialog.getByRole('button', { name: /Tic Tac Toe/ }).first().click();
    await dialog.getByRole('button', { name: 'Play square 1' }).click();
    await expect(dialog.getByRole('button', { name: /Square 1, yours/ })).toBeVisible();
    await dialog.getByRole('button', { name: 'Back', exact: true }).click();

    await dialog.getByRole('button', { name: /Rock Paper Scissors/ }).first().click();
    await dialog.getByRole('button', { name: 'Throw Rock' }).click();
    await dialog.getByRole('button', { name: 'Back', exact: true }).click();

    await dialog.getByRole('button', { name: /Snake/ }).first().click();
    await expect(dialog.getByRole('button', { name: 'Start Snake' })).toBeVisible();
  });

  test('app sandbox privacy switches change what the app shows', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Go through the app' }).click();
    const dialog = page.getByRole('dialog', { name: 'Explore Voiid' });

    await dialog.getByRole('button', { name: /Your profile/ }).click();
    const receipts = dialog.getByRole('switch', { name: /Read receipts/ });
    await expect(receipts).toHaveAttribute('aria-checked', 'true');
    await receipts.click();
    await expect(receipts).toHaveAttribute('aria-checked', 'false');

    await dialog.getByRole('button', { name: /Privacy at a glance/ }).click();
    await expect(dialog.getByRole('heading', { name: 'End-to-end encrypted' })).toBeVisible();
    await expect(dialog.getByRole('heading', { name: 'Server-readable by design' })).toBeVisible();
  });

  test('feature rail links every public product surface', async ({ page }) => {
    await page.goto('/');
    const features = page.getByRole('region', { name: 'Explore Voiid features' });

    for (const href of ['/messaging/', '/calls/', '/map/', '/clips/', '/games/']) {
      await expect(features.locator(`a[href="${href}"]`)).toHaveCount(1);
    }
  });

  test('privacy boundary and store placeholders are explicit', async ({ page }) => {
    await page.goto('/');

    await expect(page.getByRole('heading', { name: 'End-to-end encrypted' })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Server-readable by design' })).toBeVisible();
    await expect(page.getByText('Coming soon', { exact: true })).toHaveCount(2);
    await expect(page.getByText('QR code will appear here')).toBeVisible();
    await expect(page.locator('a[href="#"]')).toHaveCount(0);
  });

  test('public routes have unique SEO, one H1 and no phone overflow', async ({ page }) => {
    const routes = ['/', '/messaging/', '/calls/', '/map/', '/clips/', '/games/', '/encryption/', '/privacy/', '/invite/'];
    const titles = new Set<string>();
    const descriptions = new Set<string>();
    await page.setViewportSize({ width: 320, height: 800 });

    for (const route of routes) {
      await page.goto(route);
      await expect(page.locator('main')).toHaveCount(1);
      await expect(page.locator('h1')).toHaveCount(1);
      await expect(page.locator('link[rel="canonical"]')).toHaveAttribute('href', /^https:\/\//);
      const title = await page.title();
      const description = await page.locator('meta[name="description"]').getAttribute('content');
      expect(title.length, `${route} title`).toBeGreaterThan(20);
      expect(description?.length ?? 0, `${route} description`).toBeGreaterThan(70);
      expect(titles.has(title), `${route} title is unique`).toBeFalsy();
      expect(descriptions.has(description ?? ''), `${route} description is unique`).toBeFalsy();
      titles.add(title);
      descriptions.add(description ?? '');
      const hasOverflow = await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth);
      expect(hasOverflow, `${route} has no horizontal overflow`).toBeFalsy();
    }
  });

  test('search engines receive crawl and discovery files', async ({ request }) => {
    const robots = await request.get('/robots.txt');
    expect(robots.ok()).toBeTruthy();
    await expect(robots.text()).resolves.toContain('Sitemap: https://voiid.app/sitemap.xml');

    const sitemap = await request.get('/sitemap.xml');
    expect(sitemap.ok()).toBeTruthy();
    const xml = await sitemap.text();
    for (const route of ['', 'messaging/', 'calls/', 'map/', 'clips/', 'games/', 'encryption/', 'privacy/']) {
      expect(xml).toContain(`<loc>https://voiid.app/${route}</loc>`);
    }
    expect(xml).not.toContain('/invite/');
  });
});
