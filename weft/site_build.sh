#!/bin/bash

set -euo pipefail

cp -r "$IN/-site/." ./

if [[ "$WEFT_PIPELINE" == *"fetch"* ]]; then
    bun install
else
    bun run --bun build
    cp -r build/. "$OUT/site_build/"
fi
