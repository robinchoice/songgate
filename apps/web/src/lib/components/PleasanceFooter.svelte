<script lang="ts">
  import { page } from '$app/state';
  import AppDock from '#lib/components/AppDock.svelte';
  import { openFeedback, setTestMode, testMode } from '#lib/feedback.svelte.ts';
  import { setLocale, t } from '#lib/i18n.ts';

  const other = $derived(page.data.locale === 'de' ? 'en' : 'de');
</script>

<footer>
  <!-- Sender and wordmark link to pleasance.org, the band below is the app dock -->
  <div class="sender">
    <a href="https://pleasance.org"><span class="by">{t().madeBy}</span> <span class="wordmark" role="img" aria-label="Pleasance"></span></a>
    <AppDock />
  </div>
  <button type="button" class="feedback" onclick={() => openFeedback('idea')}>{t().giveFeedback}</button>
  <a class="legal" href={t().imprintPath}>{t().imprint}</a>
  <a class="legal" href={t().privacyPath}>{t().privacy}</a>
  <a class="legal" href={t().termsPath}>{t().terms}</a>
  <label class="legal" title={t().testModeHint}>
    <input type="checkbox" checked={testMode.on} onchange={e => setTestMode(e.currentTarget.checked)} />
    {t().testMode}
  </label>
  <button type="button" class="legal language" lang={other} onclick={() => setLocale(other)}>{t().otherLanguage}</button>
</footer>

<style>
  footer { display: flex; flex-wrap: wrap; align-items: center; gap: 12px 24px; padding: 22px 0; border-top: 1px solid var(--border); color: var(--text); font-size: 12px; }
  a { display: inline-flex; align-items: center; gap: 8px; text-decoration: none; white-space: nowrap; color: inherit; }
  /* Two columns, so the band sits under the wordmark, outside the link */
  .sender { display: inline-grid; grid-template-columns: auto 76px; gap: 5px 8px; transform: translateY(4px); }
  .sender > a { display: grid; grid-column: 1 / 3; grid-template-columns: subgrid; align-items: end; }
  .sender > :global(.dock) { grid-column: 2; }
  .by { font-family: var(--font-display); font-size: 14px; font-weight: 650; font-stretch: 80%; font-variation-settings: 'wdth' 80, 'wght' 650; line-height: 1; color: var(--muted); transform: translateY(1px); }
  .wordmark { width: 76px; height: 14px; background: currentColor; mask: url('/pleasance-wordmark.svg') left center / contain no-repeat; }
  .feedback { white-space: nowrap; padding: 0; border: none; background: none; color: var(--accent); font-size: inherit; text-decoration: underline; text-underline-offset: 3px; }
  .legal { color: var(--muted); }
  .language { white-space: nowrap; padding: 0; border: none; background: none; font-size: inherit; text-decoration: underline; text-underline-offset: 3px; cursor: pointer; }
  label { display: inline-flex; align-items: center; gap: 6px; white-space: nowrap; cursor: pointer; }
  input { margin: 0; accent-color: var(--accent); }
  @media(max-width: 650px) { footer { flex-wrap: wrap; gap: 12px 16px; font-size: 10px; } .sender { grid-template-columns: auto 68px; } .wordmark { width: 68px; height: 13px; } }
</style>
