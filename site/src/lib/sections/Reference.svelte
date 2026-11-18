<script lang="ts">
	import Head from '#lib/components/Head.svelte';
	import { reference } from '#lib';

	let activeId = $state<string>(reference[0].id);
	const active = $derived(reference.find((t) => t.id === activeId) ?? reference[0]);
	const tabs: HTMLButtonElement[] = [];

	function onKey(e: KeyboardEvent, index: number) {
		const step = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
		if (!step) return;
		e.preventDefault();
		const next = (index + step + reference.length) % reference.length;
		activeId = reference[next].id;
		tabs[next]?.focus();
	}
</script>

<section class="sec" aria-labelledby="commands">
	<div class="wrap">
		<Head cmd="weft --help" id="commands" title="Every command, one screen.">
			Arguments work positionally or as <code>-field value</code> flags. Targets read
			<code>[mode:][remote.]pipeline</code>.
		</Head>

		<div class="tabs" role="tablist" aria-label="Command groups">
			{#each reference as tab, i (tab.id)}
				<button
					bind:this={tabs[i]}
					type="button"
					role="tab"
					id="tab-{tab.id}"
					aria-selected={tab.id === activeId}
					aria-controls="panel-{tab.id}"
					tabindex={tab.id === activeId ? 0 : -1}
					onclick={() => (activeId = tab.id)}
					onkeydown={(e) => onKey(e, i)}
				>
					{tab.label} <span class="count">{tab.items.length}</span>
				</button>
			{/each}
		</div>

		<div class="table" role="tabpanel" id="panel-{active.id}" aria-labelledby="tab-{active.id}">
			<dl>
				{#each active.items as item (item.term)}
					<div>
						<dt><span class="c-dim">weft</span>{' '}{item.term}</dt>
						<dd>{item.desc}</dd>
					</div>
				{/each}
			</dl>
		</div>
	</div>
</section>

<style>
	.tabs {
		display: flex;
		gap: 4px;
		overflow-x: auto;
		border-bottom: 1px solid var(--line-2);
		scrollbar-width: none;
	}

	[role='tab'] {
		flex: none;
		padding: 14px 18px;
		font: 700 14px var(--mono);
		font-stretch: 87.5%;
		color: var(--muted);
		background: transparent;
		border: 0;
		border-bottom: 3px solid transparent;
	}

	[role='tab']:hover {
		color: var(--text);
	}

	[role='tab'][aria-selected='true'] {
		color: var(--text);
		border-bottom-color: var(--pop);
	}

	.count {
		margin-left: 4px;
		padding: 1px 7px;
		font-size: 11px;
		color: var(--dim);
		background: var(--raise);
		border-radius: 999px;
	}

	dl > div {
		display: grid;
		gap: 4px 32px;
		padding: 16px 4px;
		border-bottom: 1px solid var(--line);
	}

	@media (min-width: 820px) {
		dl > div {
			grid-template-columns: minmax(0, 1fr) minmax(0, 1.1fr);
			align-items: baseline;
		}
	}

	dt {
		font: 600 14px var(--mono);
		font-stretch: 87.5%;
		color: var(--t-yellow);
		overflow-wrap: anywhere;
	}

	dd {
		color: var(--text-2);
	}
</style>
