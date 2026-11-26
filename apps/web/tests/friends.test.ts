import { expect, test } from '@playwright/test';
import { failOnConsoleErrors, findSavior } from './fixtures.ts';

failOnConsoleErrors();

test('invalid saved entries preserve valid friends and groups after saving', async ({ page }) => {
  await page.addInitScript(() => {
    if (localStorage.getItem('musiclink-friends') !== null) return;
    localStorage.setItem('musiclink-friends', JSON.stringify({
      friends: [{ name: 'Alex', platform: 'spotify' }, { name: 'Invalid', platform: 'unknown' }],
      groups: [{ name: 'WG', members: ['Alex', 42] }, { name: null, members: [] }],
      me: {},
    }));
  });
  await findSavior(page);
  await expect(page.getByRole('button', { name: /Alex/ })).toBeVisible();
  await expect(page.getByRole('button', { name: 'WG', exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Neu', exact: false }).click();
  await page.getByPlaceholder('Name', { exact: true }).fill('Sam');
  await page.getByRole('button', { name: 'Speichern', exact: true }).click();
  await findSavior(page);
  await expect(page.getByRole('button', { name: /Alex/ })).toBeVisible();
  await expect(page.getByRole('button', { name: /Sam/ })).toBeVisible();
  await expect(page.getByRole('button', { name: 'WG', exact: true })).toBeVisible();
  const saved: unknown = await page.evaluate(() => JSON.parse(localStorage.getItem('musiclink-friends') ?? 'null'));
  expect(saved).toEqual({
    friends: [{ name: 'Alex', platform: 'spotify' }, { name: 'Sam', platform: 'spotify' }],
    groups: [{ name: 'WG', members: ['Alex'] }],
    me: null,
  });
});

test('an invite saves its sender and the own invite shows as a QR code', async ({ page }) => {
  await page.goto('/f/spotify?name=Lea');
  await page.getByRole('button', { name: 'Hier im Browser speichern' }).click();
  await expect(page.getByRole('button', { name: '✓ Lea ist gespeichert' })).toBeDisabled();
  await findSavior(page);
  await expect(page.getByRole('button', { name: /Lea/ })).toBeVisible();
  await page.getByRole('button', { name: 'Meine Einladung' }).click();
  await expect(page.getByRole('img', { name: 'QR-Code deiner Einladung' })).toHaveCount(0);
  await page.getByPlaceholder('Dein Name').fill('Robin');
  await expect(page.getByRole('img', { name: 'QR-Code deiner Einladung' }).locator('svg')).toBeVisible();
});


test('draft and result selection survive live window changes without overflow', async ({ page }) => {
  await findSavior(page);
  await page.getByRole('button', { name: 'Meine Einladung' }).click();
  await page.getByPlaceholder('Dein Name').fill('Alex');
  for (const [width, height] of [[320, 640], [640, 320], [768, 1024], [1024, 768], [1440, 900], [320, 480]]) {
    await page.setViewportSize({ width: width!, height: height! });
    await expect(page.getByPlaceholder('Dein Name')).toHaveValue('Alex');
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  }
  await page.getByRole('button', { name: 'Meine Einladung' }).click();
  await page.getByRole('button', { name: /Spotify/ }).click();
  const message = await page.locator('pre').textContent();
  for (const [width, height] of [[1440, 900], [1024, 768], [640, 320], [320, 640]]) {
    await page.setViewportSize({ width: width!, height: height! });
    await expect(page.locator('pre')).toHaveText(message!);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  }
});

const seed = (page: import('@playwright/test').Page) => page.addInitScript(() => {
  if (localStorage.getItem('musiclink-friends') !== null) return;
  localStorage.setItem('musiclink-friends', JSON.stringify({
    friends: [{ name: 'Alex', platform: 'spotify' }, { name: 'Sam', platform: 'deezer' }],
    groups: [{ name: 'WG', members: ['Alex', 'Sam'] }],
    me: null,
  }));
});
const saved = (page: import('@playwright/test').Page): Promise<unknown> => page.evaluate(() => JSON.parse(localStorage.getItem('musiclink-friends') ?? 'null'));

test('a group is removed while editing and its contacts stay', async ({ page }) => {
  await seed(page);
  await findSavior(page);
  await page.getByRole('button', { name: 'Bearbeiten' }).click();
  await page.getByRole('button', { name: 'WG entfernen' }).click();
  await expect(page.getByText('WG', { exact: true })).toHaveCount(0);
  await page.getByRole('button', { name: 'Fertig' }).click();
  await expect(page.getByRole('button', { name: /Alex/ })).toBeVisible();
  await expect(page.getByRole('button', { name: /Sam/ })).toBeVisible();
  expect(await saved(page)).toEqual({ friends: [{ name: 'Alex', platform: 'spotify' }, { name: 'Sam', platform: 'deezer' }], groups: [], me: null });
});

test('a contact changes service and name in place while editing', async ({ page }) => {
  await seed(page);
  await findSavior(page);
  await page.getByRole('button', { name: 'WG', exact: true }).click();
  await page.getByRole('button', { name: 'Bearbeiten' }).click();
  await page.getByRole('button', { name: 'Alex bearbeiten' }).click();
  await expect(page.getByText('Alex bearbeiten')).toBeVisible();
  await page.getByPlaceholder('Name', { exact: true }).fill('Alexa');
  await page.getByRole('combobox').selectOption('appleMusic');
  await page.getByRole('button', { name: 'Speichern', exact: true }).click();
  await page.getByRole('button', { name: 'Fertig' }).click();
  expect(await saved(page)).toEqual({ friends: [{ name: 'Alexa', platform: 'appleMusic' }, { name: 'Sam', platform: 'deezer' }], groups: [{ name: 'WG', members: ['Alexa', 'Sam'] }], me: null });
  await expect(page.getByRole('button', { name: 'WG', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('pre')).toContainText('Apple Music (Alexa): https://music.apple.com/de/song/1');
  await expect(page.locator('pre')).not.toContainText('Spotify');
});

test('regression: removing the last contact while editing leaves edit mode', async ({ page }) => {
  await findSavior(page);
  await page.getByRole('button', { name: 'Neu', exact: false }).click();
  await page.getByPlaceholder('Name', { exact: true }).fill('Alex');
  await page.getByRole('button', { name: 'Speichern', exact: true }).click();
  await page.getByRole('button', { name: 'Bearbeiten' }).click();
  await page.getByRole('button', { name: 'Alex entfernen' }).click();
  await expect(page.getByRole('button', { name: 'Neu', exact: false })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Alle', exact: true })).toBeVisible();
});

test('picked services offer to open their link', async ({ page }) => {
  await findSavior(page);
  await expect(page.getByRole('link', { name: /öffnen$/ })).toHaveCount(0);
  await page.getByRole('button', { name: /Deezer/ }).click();
  await page.getByRole('button', { name: /^Spotify/ }).click();
  const links = page.getByRole('link', { name: /öffnen$/ });
  await expect(links).toHaveText(['In Spotify öffnen', 'In Deezer öffnen']);
  await expect(links.first()).toHaveAttribute('href', 'https://open.spotify.com/track/x');
  await expect(links.last()).toHaveAttribute('href', 'https://www.deezer.com/search/Savior');
  await page.getByRole('button', { name: /^Spotify/ }).click();
  await expect(links).toHaveText(['In Deezer öffnen']);
});

test('regression: editing or removing an unpicked contact keeps services picked by hand', async ({ page }) => {
  await seed(page);
  await findSavior(page);
  await page.getByRole('button', { name: /^TIDAL/ }).click();
  await page.getByRole('button', { name: 'Bearbeiten' }).click();
  await page.getByRole('button', { name: 'Alex bearbeiten' }).click();
  await page.getByRole('combobox').selectOption('appleMusic');
  await page.getByRole('button', { name: 'Speichern', exact: true }).click();
  await page.getByRole('button', { name: 'Sam entfernen' }).click();
  await page.getByRole('button', { name: 'Fertig' }).click();
  await expect(page.getByRole('link', { name: /öffnen$/ })).toHaveText(['In TIDAL öffnen']);
});
