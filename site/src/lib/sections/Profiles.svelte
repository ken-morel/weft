<script lang="ts">
	import Head from '#lib/components/Head.svelte';
	import { isolations, scales } from '#lib';

	let isoId = $state<string>('kvm');
	let scaleId = $state<string>('small');

	const iso = $derived(isolations.find((i) => i.id === isoId) ?? isolations[0]);
	const scale = $derived(scales.find((s) => s.id === scaleId) ?? scales[1]);
	const profile = $derived(`${iso.id}-${scale.id}`);
	const flag = (v: boolean) => (v ? 'c-green' : 'c-red');
</script>

<section class="sec grid-bg" aria-labelledby="profiles">
	<div class="wrap">
		<Head cmd="weft remote install vps {profile}" id="profiles" title="One daemon, shaped to the host.">
			Pick how much the kernel lets weft isolate, and how hard the box can work. The daemon writes the
			result to <code>/etc/weft/weft.zon</code>.
		</Head>

		<div class="layout">
			<div class="pickers">
				<fieldset>
					<legend>isolation</legend>
					<div class="swatches two">
						{#each isolations as i (i.id)}
							<button type="button" aria-pressed={i.id === isoId} onclick={() => (isoId = i.id)}>
								<strong>{i.label}</strong><span>{i.note}</span>
							</button>
						{/each}
					</div>
				</fieldset>
				<fieldset>
					<legend>scale</legend>
					<div class="swatches three">
						{#each scales as s (s.id)}
							<button type="button" aria-pressed={s.id === scaleId} onclick={() => (scaleId = s.id)}>
								<strong>{s.label}</strong><span>{s.note}</span>
							</button>
						{/each}
					</div>
				</fieldset>
			</div>

			<div class="panel green preview" aria-live="polite">
				<div class="panel-bar"><span>/etc/weft/weft.zon</span><span>{profile}</span></div>
				<pre><span class="c-green">$ </span><span class="c-bold">weft remote install root@vps {profile}</span>

<span class="c-faint">// written by weft daemon install</span>
.{'{'}
    <span class="c-blue">.port</span> = <span class="c-yellow">9338</span>,
    <span class="c-blue">.isolate</span> = .{'{'}
        .cgroups = <span class={flag(iso.flags.cgroups)}>{iso.flags.cgroups}</span>,
        .mount = <span class={flag(iso.flags.mount)}>{iso.flags.mount}</span>,
        .pid = <span class={flag(iso.flags.pid)}>{iso.flags.pid}</span>,
        .net = <span class={flag(iso.flags.net)}>{iso.flags.net}</span>,
    {'}'},
    <span class="c-blue">.scale</span> = .{'{'}
        .max_workers = <span class="c-yellow">{scale.max_workers}</span>,
        .compress = <span class={flag(scale.compress)}>{scale.compress}</span>,
        .decompress = <span class={flag(scale.decompress)}>{scale.decompress}</span>,
    {'}'},
{'}'}</pre>
			</div>
		</div>
	</div>
</section>

<style>
	.layout {
		display: grid;
		grid-template-columns: minmax(0, 1fr);
		gap: 36px;
	}

	@media (min-width: 900px) {
		.layout {
			grid-template-columns: minmax(0, 1fr) minmax(0, 1.1fr);
			gap: 48px;
			align-items: start;
		}
	}

	fieldset {
		min-width: 0;
		margin: 0 0 26px;
		padding: 0;
		border: 0;
	}

	legend {
		margin-bottom: 12px;
		font: 600 11px var(--mono);
		letter-spacing: 0.1em;
		text-transform: uppercase;
		color: var(--dim);
	}

	.swatches {
		display: grid;
		gap: 10px;
	}

	.two {
		grid-template-columns: repeat(2, minmax(0, 1fr));
	}

	.three {
		grid-template-columns: repeat(3, minmax(0, 1fr));
	}

	.swatches button {
		display: grid;
		gap: 2px;
		padding: 14px;
		text-align: left;
		background: var(--panel);
		border: 2px solid var(--line-2);
	}

	.swatches button:hover {
		border-color: var(--dim);
	}

	.swatches button[aria-pressed='true'] {
		border-color: var(--text);
		box-shadow: 5px 5px 0 var(--pop-green);
	}

	.swatches strong {
		font: 700 16px var(--mono);
		font-stretch: 87.5%;
		color: var(--text);
	}

	.swatches span {
		font-size: 13px;
		color: var(--muted);
	}

	.preview pre {
		padding: 22px;
		font-size: 13px;
		line-height: 1.75;
		color: var(--text-2);
	}
</style>
