#!/usr/bin/env bash
# Shared env + helpers for the CentOS 7 static-musl pipeline.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUN_REPO="${BUN_REPO:-$ROOT/bun}"
OPENCODE_REPO="${OPENCODE_REPO:-$ROOT/opencode}"
OPENTUI_REPO="${OPENTUI_REPO:-$ROOT/opentui}"
OUT="${OUT:-$ROOT/output}"
OPENTUI_OUT="$OUT/opentui"

BUN_IMAGE="${BUN_IMAGE:-bun-musl-build-env}"
BUN_CONTAINER="${BUN_CONTAINER:-bun-build}"
ALPINE_IMAGE="${ALPINE_IMAGE:-alpine-oc-build}"
ALPINE_CONTAINER="${ALPINE_CONTAINER:-oc-build}"
C7_IMAGE="${C7_IMAGE:-centos:7}"
C7_CONTAINER="${C7_CONTAINER:-c7}"

PROXY="${PROXY:-http://172.18.48.1:7890}"
export HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY" http_proxy="$PROXY" https_proxy="$PROXY"

log() { printf '\033[1;36m[%s]\033[0m %s\n' "$(basename "$0")" "$*"; }
err() { printf '\033[1;31m[%s]\033[0m %s\n' "$(basename "$0")" "$*" >&2; }

# apply_patch <repo> <patch> <marker> — idempotent:
#   applies if not yet; no-ops if marker line is already present in the tree
#   (overlapping patches defeat git apply's own fwd/rev checks).
apply_patch() {
    local repo="$1" patch="$2" marker="$3"
    if grep -rqF -- "$marker" "$repo" 2>/dev/null; then
        log "already applied: $(basename "$patch")"
        return 0
    fi
    if git -C "$repo" apply --check "$patch" 2>/dev/null; then
        git -C "$repo" apply "$patch" && log "applied: $(basename "$patch")"
    else
        err "patch does not apply: $patch"
        exit 1
    fi
}

# ensure_running <container> <image> [extra run args...]
ensure_running() {
    local name="$1" image="$2"
    shift 2
    if ! docker inspect "$name" >/dev/null 2>&1; then
        docker run -d --name "$name" "$@" "$image" sleep infinity
    fi
    docker start "$name" >/dev/null 2>&1 || true
}
