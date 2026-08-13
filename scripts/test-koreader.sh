#!/usr/bin/env bash
#
# Run the KOReader-dependent specs inside a KOReader build.
#
# Prerequisites: a built KOReader with its test rocks, i.e. one where
#   koreader-emulator-*/koreader/spec/rocks/ exists. `./kodev build` produces
#   it. The AppImage does not include the test tree and cannot be used here.
#
# These specs need DocSettings, PluginLoader, the exporter Provider and the
# rest of the frontend, so they cannot run under a plain interpreter. They are
# copied into the KOReader spec tree, run with the busted that build ships, and
# then removed again -- KOReader's checkout is a reference copy and must not
# accumulate our files.
#
# Usage:
#   scripts/test-koreader.sh
#   scripts/test-koreader.sh /path/to/koreader
#   scripts/test-koreader.sh --keep       # leave the copied specs in place

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

KEEP=0
KOREADER_ROOT=""

for arg in "$@"; do
    case "${arg}" in
        --keep) KEEP=1 ;;
        -h | --help)
            sed -n '2,20p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *) KOREADER_ROOT="${arg}" ;;
    esac
done

[[ -z "${KOREADER_ROOT}" ]] && KOREADER_ROOT="${KARABRIDGE_KOREADER:-}"

if [[ ! -d "${REPO_ROOT}/spec/integration" ]]; then
    echo "no integration specs to run" >&2
    exit 0
fi

EMULATOR=""
for candidate in "${KOREADER_ROOT}"/koreader-emulator-*/koreader; do
    if [[ -d "${candidate}/spec/rocks" ]]; then
        EMULATOR="${candidate}"
        break
    fi
done

if [[ -z "${EMULATOR}" ]]; then
    cat >&2 <<EOF
No built KOReader with a test tree was found under:
  ${KOREADER_ROOT}

Build one first:
  cd ${KOREADER_ROOT} && ./kodev build

The unit suite (scripts/test-unit.sh) does not need this and covers everything
that has no KOReader dependency.
EOF
    exit 1
fi

echo "using KOReader at ${EMULATOR}"

DEST="${EMULATOR}/spec/front/unit"
mkdir -p "${DEST}"

COPIED=()
cleanup() {
    if [[ "${KEEP}" -eq 0 ]]; then
        for file in "${COPIED[@]:-}"; do
            [[ -n "${file}" ]] && rm -f "${file}"
        done
    fi
}
trap cleanup EXIT

# Only the spec files are copied. They require("spec.support.helper"), which is
# reached through the repository root added to LUA_PATH below, and which then
# works out the repository from its own location -- so the support tree stays
# where it is and there is only one copy of it.
# karakeep_api_spec belongs to scripts/test-integration.sh: it talks to a real
# server and has its own opt-in gate. Copying it here would only ever produce a
# skip, which reads like something went wrong.
shopt -s nullglob
for spec in "${REPO_ROOT}"/spec/integration/*_spec.lua; do
    if [[ "$(basename "${spec}")" == "karakeep_api_spec.lua" ]]; then
        continue
    fi
    target="${DEST}/karabridge_$(basename "${spec}")"
    cp "${spec}" "${target}"
    COPIED+=("${target}")
done
shopt -u nullglob

if [[ ${#COPIED[@]} -eq 0 ]]; then
    echo "no integration specs found in ${REPO_ROOT}/spec/integration"
    exit 0
fi

echo "+ running ${#COPIED[@]} spec file(s) with KOReader's busted"

export LUA_CPATH='?.so;common/?.so;spec/rocks/lib/lua/5.1/?.so'

# KOReader's own base path, plus two additions:
#
#   the KaraBridge plugin directory, which is what PluginLoader puts on the
#   path for the plugin it is loading;
#
#   exporter.koplugin, because `require("base")` has to resolve for the
#   highlight-exporter target. At run time PluginLoader appends *every*
#   plugin's directory once all of them are loaded, which is what makes `base`
#   reachable there; the spec run has no PluginLoader, so it is added here.
export LUA_PATH="?.lua;common/?.lua;frontend/?.lua;spec/rocks/share/lua/5.1/?.lua;spec/rocks/share/lua/5.1/?/init.lua;${EMULATOR}/plugins/exporter.koplugin/?.lua;${REPO_ROOT}/karabridge.koplugin/?.lua;${REPO_ROOT}/?.lua"

cd "${EMULATOR}"
exec env KO_HOME="${EMULATOR}/spec/run" \
    ./luajit -e 'require "busted.runner" {standalone = false}' /dev/null \
    --config-file=spec/config.lua \
    --helper=spec/helper.lua \
    --loaders=lua \
    --lazy \
    --run=front \
    --pattern='karabridge_.*_spec' \
    --output=gtest
