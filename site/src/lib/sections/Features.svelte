<script lang="ts">
	import Head from '#lib/components/Head.svelte';
	import Lines from '#lib/components/Lines.svelte';
	import { deep, features } from '#lib';
</script>

<section class="sec" aria-labelledby="features">
	<div class="wrap">
		<Head cmd="weft check --features" id="features" title="Small binary. Few assumptions.">
			Weft brings its own supervisor, package fetcher, and wire protocol, so the host only needs a
			Linux kernel and a network path back to you.
		</Head>

		<ul class="bento">
			{#each features as f (f.title)}
				<li class:wide={'wide' in f && f.wide}>
					<h3>{f.title}</h3>
					<p>{f.body}</p>
					<pre aria-hidden="true"><Lines lines={f.snippet} /></pre>
				</li>
			{/each}
		</ul>

		<dl class="deep">
			{#each deep as d (d.term)}
				<div>
					<dt>{d.term}</dt>
					<dd>{d.desc}</dd>
				</div>
			{/each}
		</dl>
	</div>
</section>

<style>
	.bento {
		display: grid;
		grid-template-columns: minmax(0, 1fr);
		gap: 16px;
	}

	@media (min-width: 720px) {
		.bento {
			grid-template-columns: repeat(2, minmax(0, 1fr));
		}
	}

	@media (min-width: 1040px) {
		.bento {
			grid-template-columns: repeat(3, minmax(0, 1fr));
		}
		.wide {
			grid-column: span 2;
		}
		.wide:last-child {
			grid-column: 1 / -1;
		}
	}

	.bento li {
		display: flex;
		flex-direction: column;
		gap: 12px;
		padding: 26px;
		background: var(--panel);
		border: 1px solid var(--line-2);
		transition: border-color 0.15s ease;
	}

	.bento li:hover {
		border-color: var(--dim);
	}

	h3 {
		font: 700 16px var(--mono);
		font-stretch: 87.5%;
		color: var(--text);
	}

	h3::before {
		content: '# ';
		color: var(--pop);
	}

	.bento p {
		color: var(--text-2);
		text-wrap: pretty;
	}

	.bento pre {
		margin-top: auto;
		padding: 12px 14px;
		font-size: 12px;
		color: var(--text-2);
		background: var(--ink);
		border: 1px solid var(--line);
	}

	.deep {
		display: grid;
		margin-top: 16px;
		border: 1px solid var(--line-2);
	}

	@media (min-width: 720px) {
		.deep {
			grid-template-columns: repeat(2, 1fr);
		}
	}

	@media (min-width: 1040px) {
		.deep {
			grid-template-columns: repeat(3, 1fr);
		}
	}

	.deep div {
		padding: 18px 22px;
		border: 1px solid var(--line);
	}

	dt {
		font: 700 14px var(--mono);
		font-stretch: 87.5%;
		color: var(--t-yellow);
	}

	dd {
		margin-top: 4px;
		font-size: 14px;
		color: var(--muted);
	}
</style>
