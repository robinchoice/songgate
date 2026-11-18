<script lang="ts">
  import Connect from '#lib/components/Connect.svelte';
  import PleasanceFooter from '#lib/components/PleasanceFooter.svelte';
  import { t } from '#lib/i18n.ts';

  let { data } = $props();
  const friend = $derived(data.friend);
</script>

<svelte:head>
  <title>{data.meta?.title ?? t().invite} · Songgate</title>
</svelte:head>

<div class="shell">
  <header><a href="/" class="brand"><img class="brand-icon" src="/favicon.svg" alt="" width="34" height="34" /> Songgate</a></header>
  <main>
    {#if friend}
      <section class="card"><Connect name={friend.name} platform={friend.platform} /></section>
    {:else}
      <section class="card"><h1>{t().inviteIncomplete}</h1><p>{t().askNewInvite}</p></section>
    {/if}
  </main>
  <PleasanceFooter />
</div>

<style>
  .shell { max-width: 560px; min-height: 100dvh; margin: auto; padding: 0 22px; display: flex; flex-direction: column; }
  header { padding: 22px 0; }
  .brand { display: inline-flex; align-items: center; gap: 10px; font-size: 24px; text-decoration: none; color: var(--text); }
  main { flex: 1; padding: 30px 0; }
  .card { background: rgb(255 255 255 / .04); border: 1px solid var(--border); border-radius: 22px; padding: 26px 22px; }
  h1 { font-size: 30px; margin: 16px 0 6px; overflow-wrap: anywhere; }
  p { color: var(--muted); font-size: 13px; margin: 0; }
</style>
