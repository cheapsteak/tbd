#!/usr/bin/env bash
# Pure launch-environment helpers for restart.sh. This file is safe to source:
# it defines functions only and does not mutate a bundle or launch processes.

require_restart_path() {
    local launch_path="${1-}"
    if [ -z "$launch_path" ]; then
        echo "error: PATH must be set and non-empty" >&2
        return 1
    fi
}

write_restart_environment_plist() {
    local source_plist="$1"
    local generated_plist="$2"
    local launch_path="${3-}"
    local working_plist
    local expected_path
    local extracted_path

    require_restart_path "$launch_path" || return 1

    working_plist="$(mktemp "${generated_plist}.tmp.XXXXXX")" || return 1
    expected_path="$(mktemp "${generated_plist}.expected.XXXXXX")" || {
        rm -f "$working_plist"
        return 1
    }
    extracted_path="$(mktemp "${generated_plist}.actual.XXXXXX")" || {
        rm -f "$working_plist" "$expected_path"
        return 1
    }

    if ! cp "$source_plist" "$working_plist" \
        || ! plutil -lint "$working_plist" >/dev/null; then
        rm -f "$working_plist" "$expected_path" "$extracted_path"
        return 1
    fi

    plutil -remove LSEnvironment "$working_plist" >/dev/null 2>&1 || true

    if ! plutil -insert LSEnvironment -xml '<dict/>' "$working_plist" \
        || ! plutil -insert LSEnvironment.PATH -string "$launch_path" "$working_plist" \
        || ! plutil -lint "$working_plist" >/dev/null \
        || ! plutil -extract LSEnvironment.PATH raw -o "$extracted_path" "$working_plist"; then
        rm -f "$working_plist" "$expected_path" "$extracted_path"
        return 1
    fi

    printf '%s' "$launch_path" > "$expected_path"
    if ! cmp -s "$expected_path" "$extracted_path"; then
        echo "error: generated LSEnvironment.PATH does not match PATH" >&2
        rm -f "$working_plist" "$expected_path" "$extracted_path"
        return 1
    fi

    if ! mv "$working_plist" "$generated_plist"; then
        rm -f "$working_plist" "$expected_path" "$extracted_path"
        return 1
    fi
    rm -f "$expected_path" "$extracted_path"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "error: source this helper from restart.sh or its test harness" >&2
    exit 64
fi
