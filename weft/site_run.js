#!/bin/env bun
const root = process.env.IN + "/site_build";
const port = Number(process.env.PORT ?? 6080);
Bun.serve({
  port,
  async fetch(req) {
    const url = new URL(req.url);
    const pathname = url.pathname === "/" ? "/index.html" : url.pathname;
    const file = Bun.file(root + pathname);
    if (await file.exists()) return new Response(file);
    const index = Bun.file(root + pathname + "/index.html");
    if (await index.exists()) return new Response(index);
    return new Response(Bun.file(root + "/404.html"), { status: 404 });
  },
});
console.log(`Serving ${root} on http://127.0.0.1:${port}`);
