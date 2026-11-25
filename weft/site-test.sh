#!/bin/bash

set -euo pipefail

cp -r "$IN/-site/." ./

bun run --bun check
