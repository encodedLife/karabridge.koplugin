#!/usr/bin/env bash
#
# Run KaraBridge's own unit tests.
#
# Prerequisites: a Lua 5.1-compatible interpreter (lua5.1, luajit or lua).
#   Optionally busted, which is preferred when present.
#
# The specs are written in busted syntax. Busted is used when it is on PATH;
# otherwise the bundled harness in spec/support/busted_lite.lua runs them, which
# implements the subset the pure-Lua specs use. Both are expected to agree, and
# CI should run at least the busted path.
#
# Usage:
#   scripts/test-unit.sh                 # every unit spec
#   scripts/test-unit.sh config          # only specs whose name contains "config"
#   KARABRIDGE_LUA=luajit scripts/test-unit.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${REPO_ROOT}"

FILTER="${1:-}"

shopt -s nullglob
if [[ -n "${FILTER}" ]]; then
    SPECS=(spec/unit/*"${FILTER}"*_spec.lua)
else
    SPECS=(spec/unit/*_spec.lua)
fi
shopt -u nullglob

if [[ ${#SPECS[@]} -eq 0 ]]; then
    echo "no spec files matched${FILTER:+ filter ${FILTER}}" >&2
    exit 1
fi

if command -v busted >/dev/null 2>&1; then
    echo "+ busted --lpath=${REPO_ROOT}/karabridge.koplugin/?.lua ${SPECS[*]}"
    exec busted \
        --lpath="${REPO_ROOT}/?.lua;${REPO_ROOT}/karabridge.koplugin/?.lua" \
        --output=utfTerminal \
        "${SPECS[@]}"
fi

LUA="${KARABRIDGE_LUA:-}"
if [[ -z "${LUA}" ]]; then
    for candidate in lua5.1 luajit lua; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            LUA="${candidate}"
            break
        fi
    done
fi

if [[ -z "${LUA}" ]]; then
    echo "no Lua interpreter found; install lua5.1, luajit or lua" >&2
    exit 1
fi

echo "note: busted is not on PATH, using the bundled harness" >&2
echo "+ ${LUA} spec/support/run_unit.lua ${SPECS[*]}"
exec "${LUA}" spec/support/run_unit.lua "${SPECS[@]}"
