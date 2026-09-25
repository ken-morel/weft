#!/usr/bin/env sh
set -eu
cp -r "$IN/src"/* .
zig build
cp -r zig-out/bin/* "$OUT/bin/"

echo "Built weft with zig"
