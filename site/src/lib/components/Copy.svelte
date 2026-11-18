<script lang="ts">
	let { text, label = 'Copy' }: { text: string; label?: string } = $props();

	let status = $state<'idle' | 'done' | 'fail'>('idle');
	let timer: ReturnType<typeof setTimeout> | undefined;

	async function copy() {
		try {
			await navigator.clipboard.writeText(text);
			status = 'done';
		} catch {
			status = 'fail';
		}
		clearTimeout(timer);
		timer = setTimeout(() => (status = 'idle'), 1800);
	}

	$effect(() => () => clearTimeout(timer));
</script>

<button type="button" class="copy" onclick={copy}>
	{status === 'done' ? 'Copied' : status === 'fail' ? 'Select it' : label}
</button>
<span class="sr-only" aria-live="polite">{status === 'done' ? 'Copied to clipboard' : ''}</span>

<style>
	.copy {
		flex: none;
		min-width: 84px;
		padding: 10px 16px;
		font: 700 13px var(--mono);
		font-stretch: 87.5%;
		color: var(--pop-ink);
		background: #fff;
		border: 2px solid var(--pop-ink);
	}

	.copy:hover {
		background: var(--pale);
	}
</style>
