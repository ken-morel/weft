<script lang="ts">
	import '../app.css';
	import favicon from '#lib/assets/favicon.svg';
	import { site } from '#lib';
	import type { LayoutProps } from './$types';

	let { children }: LayoutProps = $props();
</script>

<svelte:head>
	<title>{site.name} | {site.tagline}</title>
	<meta name="description" content={site.description} />
	<meta property="og:title" content={site.name} />
	<meta property="og:description" content={site.description} />
	<meta property="og:type" content="website" />
	<link rel="icon" href={favicon} type="image/svg+xml" />
</svelte:head>

{@render children()}
