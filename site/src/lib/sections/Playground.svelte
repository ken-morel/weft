<script lang="ts">
	import Head from '#lib/components/Head.svelte';
	import Lines from '#lib/components/Lines.svelte';
	import { demos, facts } from '#lib';

	let activeId = $state(demos[0].id);
	let piped = $state(false);

	const active = $derived(demos.find((d) => d.id === activeId) ?? demos[0]);
	const cmd = $derived(piped ? `${active.cmd} | tee deploy.log` : active.cmd);
	const showFooter = $derived(!piped && !!active.footer);
</script>

<section class="sec grid-bg" aria-labelledby="try">
	<div class="wrap">
		<Head cmd="weft do --try" id="try" title="Try it. Nothing gets deployed.">
			Pick a command and see what weft prints. Pipe it anywhere and the live footer drops away,
			leaving plain, append-only logs.
		</Head>

		<div class="play">
			<div class="rail">
				<p class="rail-label" id="rail-cmds">command</p>
				<ul aria-labelledby="rail-cmds">
					{#each demos as demo (demo.id)}
						<li>
							<button
								type="button"
								aria-pressed={demo.id === activeId}
								onclick={() => (activeId = demo.id)}
							>
								<span class="box" aria-hidden="true">{demo.id === activeId ? '[x]' : '[ ]'}</span>
								weft {demo.label}
							</button>
						</li>
					{/each}
				</ul>
				<p class="rail-label" id="rail-out">output</p>
				<ul aria-labelledby="rail-out">
					<li>
						<button type="button" aria-pressed={piped} onclick={() => (piped = !piped)}>
							<span class="box" aria-hidden="true">{piped ? '[x]' : '[ ]'}</span>
							| tee deploy.log
						</button>
					</li>
				</ul>
			</div>

			<div class="panel screen">
				<div class="panel-bar">
					<span>~/shop</span>
					<span class="live"><span class="dot" aria-hidden="true"></span>{piped ? 'PIPED' : 'LIVE'}</span>
				</div>
				{#key cmd}
					<pre class="out" aria-live="polite"><span class="c-green">$ </span><span class="c-bold"
							>{cmd}</span
						>{'\n'}<Lines lines={active.lines} />{#if showFooter && active.footer}{'\n'}<Lines
								lines={active.footer}
							/>{/if}</pre>
				{/key}
				<p class="about">{active.about}</p>
			</div>
		</div>

		<ul class="facts">
			{#each facts as f (f.label)}
				<li><strong>{f.value}</strong><span>{f.label}</span></li>
			{/each}
		</ul>
		<p class="note">Output is illustrative, following the format weft prints.</p>
	</div>
</section>

<style>
	.play {
		display: grid;
		grid-template-columns: minmax(0, 1fr);
		gap: 28px;
	}

	@media (min-width: 900px) {
		.play {
			grid-template-columns: 260px minmax(0, 1fr);
			gap: 40px;
		}
	}

	.rail ul {
		display: grid;
		gap: 4px;
		margin-bottom: 22px;
	}

	@media (max-width: 899px) {
		.rail ul {
			grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
		}
	}

	.rail-label {
		margin-bottom: 10px;
		font: 600 11px var(--mono);
		letter-spacing: 0.1em;
		text-transform: uppercase;
		color: var(--dim);
	}

	.rail button {
		display: flex;
		gap: 10px;
		width: 100%;
		padding: 9px 12px;
		font: 500 13px var(--mono);
		font-stretch: 87.5%;
		text-align: left;
		color: var(--text-2);
		background: transparent;
		border: 2px solid transparent;
	}

	.rail button:hover {
		color: var(--text);
		border-color: var(--line-2);
	}

	.rail button[aria-pressed='true'] {
		color: var(--text);
		background: var(--raise);
		border-color: var(--line-2);
	}

	.box {
		flex: none;
		white-space: pre;
		color: var(--faint);
	}

	[aria-pressed='true'] .box {
		color: var(--pop);
	}

	.screen {
		min-width: 0;
	}

	.live {
		display: inline-flex;
		gap: 8px;
		align-items: center;
		font-weight: 700;
		letter-spacing: 0.08em;
		color: var(--t-green);
	}

	.dot {
		width: 8px;
		height: 8px;
		background: currentColor;
		border-radius: 50%;
		animation: pulse 1.6s ease-in-out infinite;
	}

	@keyframes pulse {
		50% {
			opacity: 0.3;
		}
	}

	.out {
		min-height: 300px;
		padding: 20px;
		font-size: 13px;
		line-height: 1.75;
		color: var(--text-2);
		animation: show 0.25s ease-out;
	}

	@keyframes show {
		from {
			opacity: 0;
			transform: translateY(4px);
		}
	}

	.about {
		padding: 14px 20px;
		font-size: 15px;
		color: var(--muted);
		border-top: 2px solid var(--line-2);
	}

	.facts {
		display: grid;
		grid-template-columns: repeat(2, 1fr);
		margin-top: clamp(56px, 7vw, 80px);
		border: 1px solid var(--line);
	}

	@media (min-width: 900px) {
		.facts {
			grid-template-columns: repeat(4, 1fr);
		}
	}

	.facts li {
		display: grid;
		gap: 6px;
		padding: 22px 24px;
		border: 1px solid var(--line);
	}

	.facts strong {
		font: 700 clamp(30px, 3.4vw, 44px) / 1 var(--mono);
		font-stretch: 80%;
		color: var(--text);
	}

	.facts span {
		font-size: 14px;
		color: var(--muted);
	}

	.note {
		margin-top: 14px;
		font: 500 12px var(--mono);
		color: var(--faint);
	}
</style>
