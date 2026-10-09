#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/validation.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf 'OpenCode %120s\n' '' > "$tmp/tui.log"

opencode_version_matches 'opencode2 v2.0.26' '2.0.26'
! opencode_version_matches '2.0.26' '2.0.26'
! opencode_version_matches 'opencode2 v2.0.25' '2.0.26'

tui_smoke_valid 0 "$tmp/tui.log"
tui_smoke_valid 124 "$tmp/tui.log"
! tui_smoke_valid 1 "$tmp/tui.log"
printf 'Error: TUI failed\n' >> "$tmp/tui.log"
! tui_smoke_valid 0 "$tmp/tui.log"
printf 'validation fixtures passed\n'
