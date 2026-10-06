#!/usr/bin/env bash
# Render the phosphor logo.
#   phosphor.png        large render on a magenta (#FF00FF) chroma-key background
#   phosphor-small.webp small render with real transparency
# Alpha is binarized before compositing so the keyed edge is hard: no magenta
# fringe. The small version is keyed at full size, then downscaled.
#
# Usage: doc/logo/render.sh [size] [small-size]   (defaults 2048, 256)
set -euo pipefail

dir="$(cd "$(dirname "$0")" && pwd)"
size="${1:-2048}"
small="${2:-256}"
key='#FF00FF'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

rsvg-convert -w "$size" -h "$size" "$dir/phosphor.svg" -o "$tmp/raw.png"

magick "$tmp/raw.png" \
  -channel A -threshold 50% +channel \
  -background "$key" -alpha remove -alpha off \
  "$dir/phosphor.png"

magick "$dir/phosphor.png" -fuzz 1% -transparent "$key" \
  -filter Lanczos -resize "${small}x${small}" \
  -define webp:lossless=true "$dir/phosphor-small.webp"

echo "wrote $dir/phosphor.png (${size}px) and $dir/phosphor-small.webp (${small}px)"
