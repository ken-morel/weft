<script lang="ts">
	import Copy from '#lib/components/Copy.svelte';
	import Head from '#lib/components/Head.svelte';
	import { installs, site } from '#lib';

	let activeId = $state<string>(installs[0].id);
	const active = $derived(installs.find((i) => i.id === activeId) ?? installs[0]);
</script>

<section class="sec grid-bg" aria-labelledby="install">
	<div class="wrap">
		<Head cmd="weft version" id="install" title="Install it once. Point it anywhere.">
			Put the binary on your machine, then let <code>weft remote install</code> copy it to each
			server over SSH.
		</Head>

		<div class="picker">
			<ul class="list" aria-label="Install methods">
				{#each installs as m (m.id)}
					<li>
						<button type="button" aria-pressed={m.id === activeId} onclick={() => (activeId = m.id)}>
							<span class="mark" aria-hidden="true">{m.id === activeId ? '>' : ''}</span>
							<span class="name">{m.label}</span>
							<span class="sub">{m.note}</span>
						</button>
					</li>
				{/each}
			</ul>

			<div class="panel detail">
				<div class="panel-bar">
					<span>{active.label}</span>
					<Copy text={active.code} />
				</div>
				<pre><code>{active.code}</code></pre>
			</div>
		</div>
		<p class="note">
			Then write <code>weft/weft.zon</code> and run <code>weft check</code>. Full schema in the
			<a href={site.readme}>README</a>.
		</p>
	</div>
</section>

<style>
	.picker {
		display: grid;
		grid-template-columns: minmax(0, 1fr);
		gap: 28px;
	}

	@media (min-width: 900px) {
		.picker {
			grid-template-columns: 340px minmax(0, 1fr);
			gap: 40px;
			align-items: start;
		}
	}

	.list {
		display: grid;
		border-top: 1px solid var(--line-2);
	}

	.list button {
		display: grid;
		grid-template-columns: 20px 1fr;
		gap: 2px 8px;
		width: 100%;
		padding: 16px 12px;
		text-align: left;
		background: transparent;
		border: 0;
		border-bottom: 1px solid var(--line-2);
	}

	.list button:hover,
	.list button[aria-pressed='true'] {
		background: var(--raise);
	}

	.mark {
		grid-row: span 2;
		font: 700 15px var(--mono);
		color: var(--pop);
	}

	.name {
		font: 700 15px var(--mono);
		font-stretch: 87.5%;
		color: var(--text);
	}

	.sub {
		font-size: 14px;
		color: var(--muted);
	}

	.detail {
		min-width: 0;
	}

	.detail pre {
		padding: 22px;
		font-size: 13px;
		line-height: 1.8;
		color: var(--text);
	}

	.note {
		margin-top: 40px;
		color: var(--muted);
	}

	.note a {
		color: var(--text);
		text-decoration-color: var(--pop);
		text-underline-offset: 4px;
	}
</style>
