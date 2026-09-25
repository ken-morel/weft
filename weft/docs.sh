#!/usr/bin/env sh
set -eu
lowdown -s "$IN/src/README.md" -o "$OUT/README.html"
echo "Documentation built with lowdown"
