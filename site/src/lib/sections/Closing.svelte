<script lang="ts">
	import { site } from '#lib';
</script>

<section class="closing" aria-labelledby="closing-title">
	<div class="wrap inner">
		<h2 id="closing-title" class="big">weft<br />ships.</h2>
		<div class="side">
			<p>
				Build on your laptop. Run on the box in the corner, the VPS across the ocean, or the notebook
				you borrowed for an hour.
			</p>
			<div class="actions">
				<a class="cta" href="#install">Install weft</a>
				<a class="more" href={site.readme}>read the docs →</a>
			</div>
		</div>
	</div>
</section>

<style>
	.closing {
		padding-block: clamp(72px, 10vw, 128px);
		color: var(--pop-ink);
		background: var(--pop);
		border-block: 3px solid var(--pop-ink);
	}

	.inner {
		display: grid;
		gap: 36px;
		align-items: end;
	}

	@media (min-width: 900px) {
		.inner {
			grid-template-columns: 1.3fr 1fr;
		}
	}

	.big {
		font: 900 clamp(56px, 11vw, 150px) / 0.9 var(--display);
		letter-spacing: -0.06em;
	}

	.side p {
		max-width: 36ch;
		font-size: clamp(18px, 1.7vw, 21px);
		font-weight: 500;
		line-height: 1.45;
	}

	.actions {
		display: flex;
		flex-wrap: wrap;
		gap: 20px 28px;
		align-items: center;
		margin-top: 28px;
	}

	.cta {
		padding: 16px 26px;
		font: 700 16px var(--mono);
		font-stretch: 87.5%;
		color: #fff;
		text-decoration: none;
		background: var(--pop-red);
		border: 3px solid var(--pop-ink);
		box-shadow: 6px 6px 0 var(--pop-ink);
		transition:
			transform 0.12s ease,
			box-shadow 0.12s ease;
	}

	.cta:hover {
		transform: translate(-2px, -2px);
		box-shadow: 8px 8px 0 var(--pop-ink);
	}

	.cta:active {
		transform: translate(4px, 4px);
		box-shadow: 2px 2px 0 var(--pop-ink);
	}

	.more {
		font: 700 14px var(--mono);
		font-stretch: 87.5%;
		text-underline-offset: 5px;
	}

	.closing :focus-visible {
		outline-color: var(--pop-ink);
	}
</style>
