# weft landing page

Static landing page for weft, with a layout inspired by [eza.rocks](https://eza.rocks).
Built with SvelteKit and `@sveltejs/adapter-static`.

eza.rocks is AGPL-3.0, so none of its code is copied here; only the visual
direction is borrowed.

## Structure

- `src/lib/content.ts`: all copy and data. Keep it in sync with the root
  `README.md`. The terminal demos follow the output format in
  `src/client/View.zig` and `src/client/cmd_logs.zig`.
- `src/lib/sections/`: one component per page section (Hero, Playground,
  Features, Install, Reference, Profiles, Migrate, Closing, Footer).
- `src/lib/components/`: shared pieces (`Lines`, `Copy`, `Head`).
- `src/app.css`: design tokens, panels, offset shadows, colour classes.

Fonts (Unbounded, Instrument Sans, Martian Mono) are self-hosted via
Fontsource, so the page makes no third-party requests.

## Develop

```sh
cd site
npm ci
npm run dev        # http://localhost:5173
npm run check      # type and Svelte diagnostics
```

## Build

```sh
BASE_PATH=/weft npm run build   # output in site/build
npm run preview
```

`BASE_PATH` must match the URL prefix the site is served from
(`/<repo>` for GitHub project pages, empty for a custom domain).

## Deploy

`.github/workflows/pages.yml` builds and publishes to GitHub Pages on every
push to `dev` that touches `site/`. Enable it once under
**Settings → Pages → Source: GitHub Actions**.
