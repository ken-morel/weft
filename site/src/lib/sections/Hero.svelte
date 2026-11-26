<script lang="ts">
	import Copy from '#lib/components/Copy.svelte';
	import Lines from '#lib/components/Lines.svelte';
	import { heroAfter, heroBefore, heroStickers, heroTiles, installCommand, nav, site } from '#lib';
</script>

<section class="hero" aria-labelledby="hero-title">
	<nav class="wrap bar" aria-label="Primary">
		<a class="brand" href="#top">weft</a>
		<ul class="links">
			{#each nav as item (item.href)}
				<li><a href={item.href}>{item.label}</a></li>
			{/each}
		</ul>
		<a class="btn gh" href={site.repo}>GitHub <span aria-hidden="true">↗</span></a>
	</nav>

	<div class="wrap grid">
		<div class="intro">
			<h1 id="hero-title" class="title">
				Weave your <span class="chip">deploys</span>.
			</h1>
			<p class="pitch">
				One static binary builds on your laptop, ships the artifacts, and runs your pipelines on a
				small VPS, an LXC box, or a Colab notebook. No Docker. No Nix install.
			</p>

			<div class="install">
				<span class="dollar" aria-hidden="true">$</span>
				<code class="cmd">{installCommand}</code>
				<Copy text={installCommand} />
			</div>
			<p class="meta">Linux x86_64 / aarch64 · nightly · Zig master · MIT</p>

			<div class="legend">
				<span class="legend-label">runs on</span>
				<ul class="tiles">
					{#each heroTiles as tile (tile.label)}
						<li><strong>{tile.label}</strong><span>{tile.note}</span></li>
					{/each}
				</ul>
			</div>
		</div>

		<figure class="collage">
			<div class="card old" aria-hidden="true">
				<p class="card-title">deploy.sh · before</p>
				<pre>{#each heroBefore as line, i (i)}<span class:c-faint={line.startsWith('#')}
							>{line}</span
						>{'\n'}{/each}</pre>
			</div>
			<div class="card new">
				<p class="card-title"><span>weft · today</span><span aria-hidden="true">● ● ●</span></p>
				<pre aria-hidden="true"><Lines lines={heroAfter} /></pre>
			</div>
			<span class="sticker round" aria-hidden="true">1<br />binary</span>
			{#each heroStickers as s, i (s.text)}
				<span class="sticker pill {s.tone} p{i}" style:--tilt="{s.tilt}deg" aria-hidden="true"
					>{s.text}</span
				>
			{/each}
			<figcaption class="sr-only">
				Before: a hand-written script of scp and ssh commands. With weft: one command builds
				locally, pushes the artifact to the VPS, and starts the server.
			</figcaption>
		</figure>
	</div>
</section>

<style>
	.hero {
		position: relative;
		overflow: hidden;
		padding-bottom: clamp(64px, 8vw, 104px);
		color: var(--pop-ink);
		background: var(--pop);
		border-bottom: 3px solid var(--pop-ink);
	}

	.bar {
		display: flex;
		gap: 24px;
		align-items: center;
		justify-content: space-between;
		padding-block: 22px;
	}

	.brand {
		font: 900 26px/1 var(--display);
		letter-spacing: -0.05em;
		text-decoration: none;
	}

	.links {
		display: none;
		gap: 28px;
		margin-inline: auto;
	}

	.links a {
		font: 700 14px var(--mono);
		font-stretch: 87.5%;
		text-decoration: none;
	}

	.links a:hover {
		text-decoration: underline 2px;
		text-underline-offset: 5px;
	}

	.gh {
		padding: 9px 16px;
		border-radius: 999px;
	}

	@media (min-width: 860px) {
		.links {
			display: flex;
		}
	}

	.grid {
		display: grid;
		gap: clamp(56px, 7vw, 72px);
		padding-top: clamp(28px, 5vw, 64px);
	}

	@media (min-width: 1080px) {
		.grid {
			grid-template-columns: minmax(0, 1.25fr) minmax(0, 1fr);
			align-items: center;
		}
	}

	.intro {
		min-width: 0;
	}

	.title {
		font: 900 clamp(42px, 9.6vw, 128px) / 0.95 var(--display);
		letter-spacing: -0.055em;
	}

	@media (min-width: 1080px) {
		.title {
			font-size: clamp(56px, 7.2vw, 104px);
		}
	}

	.chip {
		display: inline-block;
		padding: 0.02em 0.16em 0.08em;
		margin-top: 0.08em;
		color: var(--pop);
		background: var(--pop-ink);
		transform: rotate(-2.5deg);
	}

	.pitch {
		max-width: 34ch;
		margin-top: clamp(22px, 3vw, 32px);
		font-size: clamp(19px, 1.9vw, 24px);
		font-weight: 500;
		line-height: 1.4;
		text-wrap: pretty;
	}

	.install {
		display: flex;
		gap: 12px;
		align-items: center;
		max-width: 640px;
		margin-top: 32px;
		padding: 10px 10px 10px 18px;
		color: var(--text);
		background: var(--pop-ink);
		border: 3px solid var(--pop-ink);
		box-shadow: 7px 7px 0 var(--pop-red);
	}

	.dollar {
		font: 700 15px var(--mono);
		color: var(--pop);
	}

	.cmd {
		flex: 1;
		min-width: 0;
		overflow: hidden;
		font-size: 13px;
		white-space: nowrap;
		text-overflow: ellipsis;
	}

	.meta {
		margin-top: 18px;
		font: 600 12px var(--mono);
		font-stretch: 87.5%;
	}

	.legend {
		display: flex;
		flex-wrap: wrap;
		gap: 12px 16px;
		align-items: center;
		margin-top: 28px;
	}

	.legend-label {
		font: 700 12px var(--mono);
		font-stretch: 87.5%;
		text-transform: uppercase;
		letter-spacing: 0.08em;
	}

	.tiles {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
	}

	.tiles li {
		display: grid;
		padding: 6px 12px;
		line-height: 1.25;
		background: #fff;
		border: 2px solid var(--pop-ink);
	}

	.tiles strong {
		font: 700 13px var(--mono);
		font-stretch: 87.5%;
	}

	.tiles span {
		font-size: 11px;
		font-weight: 600;
	}

	/* collage */
	.collage {
		position: relative;
		min-width: 0;
		padding: 0 12px 24px 0;
	}

	.card {
		border: 3px solid var(--pop-ink);
	}

	.card pre {
		padding: 16px 18px;
		font-size: 12px;
		line-height: 1.7;
	}

	.card-title {
		display: flex;
		justify-content: space-between;
		padding: 8px 14px;
		font: 700 12px var(--mono);
		font-stretch: 87.5%;
		border-bottom: 3px solid var(--pop-ink);
	}

	.old {
		width: 86%;
		background: var(--paper);
		transform: rotate(-3deg);
	}

	.old pre {
		color: #3b3b3b;
	}

	.old .c-faint {
		color: #8a8579;
	}

	.new {
		position: relative;
		z-index: 1;
		margin: -28px 0 0 auto;
		width: 94%;
		color: var(--text);
		background: var(--ink);
		box-shadow: 14px 14px 0 var(--pop-blue);
		transform: rotate(1.5deg);
	}

	.new .card-title {
		color: var(--pop-ink);
		background: #fff;
	}

	.sticker {
		position: absolute;
		z-index: 2;
		font: 700 13px/1.1 var(--mono);
		font-stretch: 87.5%;
		border: 3px solid var(--pop-ink);
	}

	.round {
		top: -26px;
		right: 2%;
		display: grid;
		place-items: center;
		width: 92px;
		height: 92px;
		color: #fff;
		text-align: center;
		background: var(--pop-red);
		border-radius: 50%;
		transform: rotate(12deg);
	}

	.pill {
		padding: 7px 14px;
		border-radius: 999px;
		transform: rotate(var(--tilt));
	}

	.pill.blue {
		color: #fff;
		background: var(--pop-blue);
	}
	.pill.green {
		background: var(--pop-green);
	}
	.pill.paper {
		background: var(--paper);
	}

	.p0 {
		top: 38%;
		left: -14px;
	}
	.p1 {
		right: -6px;
		bottom: 4px;
	}
	.p2 {
		bottom: -12px;
		left: 18%;
	}

	@media (max-width: 560px) {
		.old {
			width: 100%;
		}
		.new {
			width: 100%;
		}
		.p0 {
			display: none;
		}
	}
</style>
