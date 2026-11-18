<script lang="ts">
	import type { Line } from '#lib';

	let { lines }: { lines: readonly Line[] } = $props();
</script>

{#each lines as line, i (i)}{#each line as [text, tone], j (j)}<span class={tone ? `c-${tone}` : undefined}
			>{text}</span
		>{/each}{'\n'}{/each}
