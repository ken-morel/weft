#!/bin/bash

set -eu

cp -r $IN/-site/* ./

if [[ "$WEFT_PIPELINE" == *"fetch"* ]]; then
    bun install
else
    bun install --offline --frozen-lockfile || true
    bun run build
    cp -r build/* $OUT/site-build/
fi