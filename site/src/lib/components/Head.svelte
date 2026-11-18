<script lang="ts">
	import type { Snippet } from 'svelte';

	let { cmd, id, title, children }: { cmd: string; id: string; title: string; children?: Snippet } =
		$props();
</script>

<header class="head">
	<div>
		<span class="eyebrow">{cmd}</span>
		<h2 class="h2" {id}>{title}</h2>
	</div>
	{#if children}
		<p class="lead">{@render children()}</p>
	{/if}
</header>
