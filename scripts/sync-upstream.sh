#!/usr/bin/env bash
# Sync the three upstream repos to the pins in versions.json and preflight
# every patch against the freshly checked-out trees.
#
#   scripts/sync-upstream.sh [bun_ref] [opencode_ref] [opentui_ref]
#
# Any arg (or --keep for "don't touch that repo") overrides versions.json.
# On a fresh checkout this clones shallowly; existing repos are hard-reset
# to the pin (local changes are discarded — the pipeline only ever applies
# our patches, never edits upstream by hand).
set -euo pipefail
source "$(dirname "$0")/env.sh"

# proxied HTTP/2 can stall mid-clone; HTTP/1.1 is slower but reliable
git config --global http.version HTTP/1.1

KEEP_ARGS=()
for a in "$@"; do
    case "$a" in
        bun|opencode|opentui) KEEP_ARGS+=("$a") ;;
    esac
done
is_kept() { [[ " ${KEEP_ARGS[*]:-} " == *" $1 "* ]]; }

# positional args override versions.json
BUN_REF="${1:-$(read_ref bun ref)}"
OPENCODE_REF="${2:-$(read_ref opencode ref)}"
OPENTUI_REF="${3:-$(read_ref opentui ref)}"

sync_one() {
    local name="$1" ref="$2" kind="$3" dir="$4" url="$5"
    shift 5
    if is_kept "$name"; then
        log "keeping local $name ($(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo 'no repo'))"
        return 0
    fi
    mkdir -p "$(dirname "$dir")"
    if [ ! -d "$dir/.git" ]; then
        log "cloning $name ($ref)..."
        n=0
        until git clone --depth 1 --no-checkout "$url" "$dir"; do
            n=$((n + 1))
            [ "$n" -lt 3 ] || { err "clone $name failed"; exit 1; }
            log "clone retry $n/3 ($name)"
            rm -rf "$dir"
            sleep 5
        done
        git -C "$dir" remote set-url origin "$url"
    fi
    log "fetching $name $ref..."
    git -C "$dir" fetch --depth 1 --no-tags origin "$ref" || {
        err "cannot fetch $name $ref"; exit 1
    }
    git -C "$dir" checkout -f FETCH_HEAD
    # keep the CI-cached build products (they live inside the repos):
    #   bun/build/release-musl-static (ninja + rust incremental)
    #   opencode node_modules (bun install)
    case "$name" in
        bun) git -C "$dir" clean -fdx -e build/release-musl-static ;;
        opencode) git -C "$dir" clean -fdx -e node_modules -e packages/opencode/node_modules ;;
        *) git -C "$dir" clean -fdx ;;
    esac
    git -C "$dir" config user.email "ci@local" 2>/dev/null || true
    git -C "$dir" config user.name "ci" 2>/dev/null || true
    local sha
    sha="$(git -C "$dir" rev-parse HEAD)"
    log "$name @ $ref -> $sha"
    printf '%s\n' "$sha" > "$OUT/upstream/$name.sha"
    echo "$name"
}

# Patches may be stacked (bun-flags-dlopen builds on bun-flags-static), so
# preflight applies them in order on the pristine tree and then resets it.
preflight_patches() {
    local name="$1" dir="$2"
    shift 2
    local failed=0
    for p in "$@"; do
        if git -C "$dir" apply "$p" 2>/dev/null; then
            log "preflight OK: $(basename "$p") ($name)"
        else
            err "patch does not apply on $name: $p"
            err "upstream changed the context — rework the patch (see README 'Upgrading upstreams')."
            failed=1
            break
        fi
    done
    git -C "$dir" checkout -- .
    [ "$failed" -eq 0 ]
}

mkdir -p "$OUT/upstream"

sync_one bun "$BUN_REF" "$(read_ref bun kind)" "$BUN_REPO" "$(upstream_url bun)"
sync_one opencode "$OPENCODE_REF" "$(read_ref opencode kind)" "$OPENCODE_REPO" "$(upstream_url opencode)"
sync_one opentui "$OPENTUI_REF" "$(read_ref opentui kind)" "$OPENTUI_REPO" "$(upstream_url opentui)"

preflight_patches bun "$BUN_REPO" \
    "$ROOT/patches/bun-flags-static.patch" \
    "$ROOT/patches/bun-flags-dlopen.patch"
preflight_patches opencode "$OPENCODE_REPO" \
    "$ROOT/patches/opencode-build-targets.patch"
preflight_patches opentui "$OPENTUI_REPO" \
    "$ROOT/patches/opentui-static-lib.patch"

log "sync OK — upstream SHAs in $OUT/upstream/"
