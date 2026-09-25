#!/usr/bin/env sh
set -eu
cp -r "$IN/src"/* .
zig build --cache-dir .zig-cache --prefix "$OUT"
echo "Built weft with zig"
