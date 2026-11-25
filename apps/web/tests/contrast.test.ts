import { readFileSync } from 'node:fs';
import { bandColor, GLOW } from '@app/shared';
import { expect, test } from '@playwright/test';

// WCAG contrast of the colour pairs from starter's design rules, on Songgate's
// dark ground. Values come from where they are defined: the rendered web layout
// and the app's brand.dart. Text needs 4.5:1, a focus ring 3:1. --accent draws
// the focus ring but is held to 4.5:1, so it passes both.

function luminance(hex: string): number {
  const [r, g, b] = [1, 3, 5].map((i) => {
    const v = Number.parseInt(hex.slice(i, i + 2), 16) / 255;
    return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r! + 0.7152 * g! + 0.0722 * b!;
}

function contrast(a: string, b: string): number {
  const [light, dark] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (light! + 0.05) / (dark! + 0.05);
}

type Pair = [foreground: string, background: string, minimum: number];

// Lists every failing pair, so one run shows all of them
function failures(colors: Record<string, string>, pairs: Pair[]): string[] {
  return pairs.flatMap(([fg, bg, minimum]) => {
    // #fff becomes #ffffff
    const [a, b] = [colors[fg], colors[bg]].map((c) => c?.replace(/^#(\w)(\w)(\w)$/, '#$1$1$2$2$3$3'));
    if (!a?.match(/^#[0-9a-f]{6}$/i) || !b?.match(/^#[0-9a-f]{6}$/i)) return [`${fg} on ${bg}: not a hex colour`];
    const ratio = contrast(a, b);
    return ratio < minimum ? [`${fg} ${a} on ${bg} ${b}: ${ratio.toFixed(2)} < ${minimum}`] : [];
  });
}

// Every position of the band, as products pick any section of it
const positions = Array.from({ length: 601 }, (_, i) => 1 + i / 100);

test('web layout colours keep their contrast', async ({ page }) => {
  await page.goto('/');
  const colors: Record<string, string> = await page.evaluate(() => {
    const root = getComputedStyle(document.documentElement);
    const app = document.querySelector('.root');
    const names = ['--bg', '--surface', '--raised', '--text', '--muted', '--error', '--ink'];
    const tokens = Object.fromEntries(names.map((name) => [name, root.getPropertyValue(name).trim()]));
    return { ...tokens, '--accent': app ? getComputedStyle(app).getPropertyValue('--accent').trim() : '' };
  });
  const pairs: Pair[] = [];
  for (const bg of ['--bg', '--surface', '--raised']) {
    // --accent colours links as well as the focus ring, so it is held to text contrast
    for (const fg of ['--text', '--muted', '--error', '--accent']) pairs.push([fg, bg, 4.5]);
  }
  // Ink on filled signals and on gradient surfaces, glow as text on the dark ground
  pairs.push(['--ink', '--error', 4.5]);
  for (const p of positions) {
    colors[`glow ${p}`] = bandColor(p, GLOW);
    pairs.push(['--ink', `glow ${p}`, 4.5], [`glow ${p}`, '--bg', 4.5], [`glow ${p}`, '--surface', 4.5]);
  }
  expect(failures(colors, pairs)).toEqual([]);
});

test('app brand colours keep their contrast', () => {
  const dart = readFileSync(new URL('../../mobile/lib/core/brand.dart', import.meta.url), 'utf8');
  const colors = Object.fromEntries(
    [...dart.matchAll(/^const (\w+) = Color\(0xFF([0-9A-F]{6})\);/gm)].map(([, name, hex]) => [name, `#${hex}`]),
  );
  const pairs: Pair[] = [['ink', 'errorGlow', 4.5]];
  for (const bg of ['background', 'surface', 'raised']) {
    for (const fg of ['text', 'muted', 'errorGlow']) pairs.push([fg, bg, 4.5]);
  }
  expect(failures(colors, pairs)).toEqual([]);
  // The band pairs above hold for the app only while its glow tones are the web's
  const glow = dart.match(/^const glow = \[([^\]]+)\];/m)?.[1] ?? '';
  expect([...glow.matchAll(/0xFF([0-9A-F]{6})/g)].map(([, hex]) => `#${hex}`)).toEqual(GLOW);
});
