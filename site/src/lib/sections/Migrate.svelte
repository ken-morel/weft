<script lang="ts">
	import Head from '#lib/components/Head.svelte';
	import { migration } from '#lib';
</script>

<section class="sec" aria-labelledby="migrate">
	<div class="wrap">
		<Head cmd="diff deploy.sh weft/weft.zon" id="migrate" title="Coming from a deploy script?">
			Drop the build, push, pull, and restart routine. Describe two pipelines and weft moves the
			artifact and replaces the running server for you.
		</Head>

		<div class="panel blue diff">
			<pre><span class="c-cyan">@@ {migration.from} → weft/weft.zon @@</span>
{#each migration.removed as line (line)}<span class="row del"><span class="sign">-</span>{line}</span
					>{/each}{#each migration.added as line (line)}<span class="row add"
						><span class="sign">+</span>{line}</span
					>{/each}<span class="c-faint"># {migration.note}</span></pre>
		</div>
	</div>
</section>

<style>
	.diff pre {
		padding: 22px 0;
		font-size: 13px;
		line-height: 1.9;
		color: var(--text-2);
	}

	.diff pre > span {
		display: block;
		padding-inline: 22px;
	}

	.sign {
		display: inline-block;
		width: 2ch;
		font-weight: 700;
	}

	.del {
		color: #f3b1a8;
		background: rgb(240 123 110 / 0.1);
	}

	.del .sign {
		color: var(--t-red);
	}

	.add {
		color: #cdeec2;
		background: rgb(139 212 117 / 0.1);
	}

	.add .sign {
		color: var(--t-green);
	}
</style>
