#!/usr/bin/env sh
set -eu
cp -r "$IN/src"/* .
zig build --cache-dir .zig-cache --prefix "$OUT"

cp zig-out/bin/weft $OUT/bin/

echo "Built weft with zig"
