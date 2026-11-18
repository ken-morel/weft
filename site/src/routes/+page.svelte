<script lang="ts">
	import Closing from '#lib/sections/Closing.svelte';
	import Features from '#lib/sections/Features.svelte';
	import Footer from '#lib/sections/Footer.svelte';
	import Hero from '#lib/sections/Hero.svelte';
	import Install from '#lib/sections/Install.svelte';
	import Migrate from '#lib/sections/Migrate.svelte';
	import Playground from '#lib/sections/Playground.svelte';
	import Profiles from '#lib/sections/Profiles.svelte';
	import Reference from '#lib/sections/Reference.svelte';
</script>

<a class="skip" href="#main">Skip to content</a>
<div id="top">
	<Hero />
	<main id="main">
		<Playground />
		<Features />
		<Install />
		<Reference />
		<Profiles />
		<Migrate />
		<Closing />
	</main>
	<Footer />
</div>
