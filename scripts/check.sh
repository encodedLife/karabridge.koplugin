#!/usr/bin/env bash
#
# Static checks: syntax, accidental globals, lint, shell scripts, formatting.
#
# Prerequisites (each is skipped with a note when absent):
#   luac5.1 / luac  syntax and accidental-global detection
#   luacheck        Lua linting, configured by .luacheckrc
#   stylua          Lua formatting, configured by stylua.toml
#   ShellCheck      shell script linting
#
# Usage:
#   scripts/check.sh          # report problems
#   scripts/check.sh --fix    # let stylua rewrite files

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${REPO_ROOT}"

FIX=0
[[ "${1:-}" == "--fix" ]] && FIX=1

STATUS=0
note() { printf '\n== %s\n' "$1"; }
skip() { printf 'skipped: %s is not installed\n' "$1"; }

mapfile -t LUA_FILES < <(find karabridge.koplugin spec -name '*.lua' | sort)
mapfile -t SH_FILES < <(find scripts -name '*.sh' | sort)

note "syntax (${#LUA_FILES[@]} Lua files)"
LUAC="$(command -v luac5.1 || command -v luac || true)"
if [[ -z "${LUAC}" ]]; then
    skip "luac5.1"
else
    for file in "${LUA_FILES[@]}"; do
        if ! out="$("${LUAC}" -p "${file}" 2>&1)"; then
            echo "syntax: ${file}: ${out}"
            STATUS=1
        fi
    done
    [[ "${STATUS}" -eq 0 ]] && echo "ok"
fi

# luac -l lists the opcodes; a SETGLOBAL means a name was assigned without
# `local`, which Lua accepts silently and which then leaks between plugins
# sharing one Lua state. KOReader's own Makefile checks for this too.
note "accidental globals"
if [[ -z "${LUAC}" ]]; then
    skip "luac5.1"
else
    globals=0
    for file in "${LUA_FILES[@]}"; do
        if "${LUAC}" -l -p "${file}" 2>/dev/null | grep -q SETGLOBAL; then
            echo "global assignment in ${file}:"
            "${LUAC}" -l -p "${file}" | grep SETGLOBAL
            globals=1
        fi
    done
    [[ "${globals}" -eq 1 ]] && STATUS=1 || echo "ok"
fi

note "luacheck"
if ! command -v luacheck >/dev/null 2>&1; then
    skip "luacheck"
else
    luacheck karabridge.koplugin spec scripts || STATUS=1
fi

note "shellcheck (${#SH_FILES[@]} scripts)"
if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck"
else
    shellcheck "${SH_FILES[@]}" && echo "ok" || STATUS=1
fi

note "stylua"
if ! command -v stylua >/dev/null 2>&1; then
    skip "stylua"
elif [[ "${FIX}" -eq 1 ]]; then
    stylua karabridge.koplugin spec && echo "formatted"
else
    stylua --check karabridge.koplugin spec && echo "ok" || STATUS=1
fi

printf '\n'
if [[ "${STATUS}" -eq 0 ]]; then
    echo "all available checks passed"
else
    echo "checks failed"
fi
exit "${STATUS}"
