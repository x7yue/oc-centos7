#!/usr/bin/env bash
# Build the two docker images the pipeline uses:
#   bun-musl-build-env  (Ubuntu 24.04 + LLVM 21 + nightly rust + musl sysroot)
#   alpine-oc-build     (alpine 3.23 for the opencode standalone step)
set -euo pipefail
source "$(dirname "$0")/env.sh"

log "building $BUN_IMAGE..."
docker build -t "$BUN_IMAGE" -f "$ROOT/docker/Dockerfile.bunmusl" "$ROOT"

log "building $ALPINE_IMAGE..."
docker build -t "$ALPINE_IMAGE" -f "$ROOT/docker/Dockerfile.alpine-oc" "$ROOT"

log "images ready: $BUN_IMAGE, $ALPINE_IMAGE"
