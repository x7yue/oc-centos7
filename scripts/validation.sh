#!/usr/bin/env bash
# Assertions shared by the build cache and CentOS 7 smoke checks.

opencode_version_matches() {
    [ "$1" = "opencode2 v$2" ]
}

tui_smoke_valid() {
    local status="$1" log_file="$2"
    { [ "$status" -eq 0 ] || [ "$status" -eq 124 ]; } \
        && [ "$(wc -c < "$log_file")" -ge 100 ] \
        && grep -q 'OpenCode' "$log_file" \
        && ! grep -Eqi 'Failed to open library|Dynamic loading not supported|Error:|panic:' "$log_file"
}
