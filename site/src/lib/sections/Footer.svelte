<script lang="ts">
	import { site } from '#lib';

	const links = [
		{ href: site.repo, label: 'GitHub' },
		{ href: site.changelog, label: 'Changelog' },
		{ href: site.styleguide, label: 'Style guide' },
		{ href: site.license, label: 'MIT' }
	];
</script>

<footer class="foot">
	<div class="wrap inner">
		<p>
			<strong>weft</strong> is built by
			<a href={site.maintainer.url}>{site.maintainer.name}</a>. Page design inspired by
			<a href={site.inspiration}>eza.rocks</a>.
		</p>
		<ul>
			{#each links as l (l.label)}
				<li><a href={l.href}>{l.label}</a></li>
			{/each}
		</ul>
	</div>
</footer>

<style>
	.foot {
		padding-block: 36px;
		font-size: 14px;
		color: var(--muted);
	}

	.inner {
		display: flex;
		flex-wrap: wrap;
		gap: 16px 32px;
		align-items: center;
		justify-content: space-between;
	}

	strong {
		color: var(--text);
	}

	a {
		color: var(--text-2);
		text-underline-offset: 4px;
	}

	ul {
		display: flex;
		flex-wrap: wrap;
		gap: 8px 22px;
	}

	ul a {
		font: 600 13px var(--mono);
		font-stretch: 87.5%;
		text-decoration: none;
	}

	ul a:hover {
		color: var(--pop);
	}
</style>
