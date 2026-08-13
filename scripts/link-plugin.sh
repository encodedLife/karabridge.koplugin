#!/usr/bin/env bash
#
# Symlink the installable plugin folder into a KOReader tree, so the emulator
# runs the working copy rather than a snapshot of it.
#
# Prerequisites: a KOReader checkout or emulator build. By default the
#   path in $KARABRIDGE_KOREADER is used; both its
#   plugins/ directory and any built emulator tree under it are linked.
#
# Usage:
#   scripts/link-plugin.sh /path/to/koreader  # link into that KOReader
#   scripts/link-plugin.sh                    # uses $KARABRIDGE_KOREADER
#   scripts/link-plugin.sh --unlink           # remove the links again
#
# All paths are derived from this script's own location, so there is no
# hard-coded username and the repository can live anywhere.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PLUGIN_SOURCE="${REPO_ROOT}/karabridge.koplugin"
PLUGIN_NAME="karabridge.koplugin"

UNLINK=0
KOREADER_ROOT=""

for arg in "$@"; do
    case "${arg}" in
        --unlink) UNLINK=1 ;;
        -h | --help)
            sed -n '2,20p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *) KOREADER_ROOT="${arg}" ;;
    esac
done

if [[ -z "${KOREADER_ROOT}" ]]; then
    KOREADER_ROOT="${KARABRIDGE_KOREADER:-}"
fi

if [[ ! -d "${PLUGIN_SOURCE}" ]]; then
    echo "plugin source not found: ${PLUGIN_SOURCE}" >&2
    exit 1
fi

if [[ ! -d "${KOREADER_ROOT}" ]]; then
    echo "KOReader tree not found: ${KOREADER_ROOT}" >&2
    exit 1
fi

# A source checkout has plugins/ at the top; a built emulator has its own copy
# under koreader-emulator-*/koreader/plugins. Both are linked when present, so
# `kodev run` and a directly launched emulator agree on which plugin is loaded.
TARGET_DIRS=()
[[ -d "${KOREADER_ROOT}/plugins" ]] && TARGET_DIRS+=("${KOREADER_ROOT}/plugins")
for emulator in "${KOREADER_ROOT}"/koreader-emulator-*/koreader/plugins; do
    [[ -d "${emulator}" ]] && TARGET_DIRS+=("${emulator}")
done

if [[ ${#TARGET_DIRS[@]} -eq 0 ]]; then
    echo "no plugins directory found under ${KOREADER_ROOT}" >&2
    exit 1
fi

for plugins_dir in "${TARGET_DIRS[@]}"; do
    target="${plugins_dir}/${PLUGIN_NAME}"

    if [[ "${UNLINK}" -eq 1 ]]; then
        if [[ -L "${target}" ]]; then
            echo "+ rm ${target}"
            rm "${target}"
        elif [[ -e "${target}" ]]; then
            echo "refusing to remove ${target}: it is a real directory, not a link" >&2
            exit 1
        fi
        continue
    fi

    # Replacing our own symlink is routine. Replacing a real directory is not:
    # it is most likely a manually installed copy with the user's karabridge.conf
    # in it, and deleting that without asking would be data loss.
    if [[ -e "${target}" && ! -L "${target}" ]]; then
        echo "refusing to replace ${target}" >&2
        echo "It is a real directory, not a symlink. Move it aside first." >&2
        exit 1
    fi

    echo "+ ln -sfnT ${PLUGIN_SOURCE} ${target}"
    ln -sfnT "${PLUGIN_SOURCE}" "${target}"
    echo "  ${target} -> $(readlink -f "${target}")"
done

if [[ "${UNLINK}" -eq 1 ]]; then
    echo "unlinked ${PLUGIN_NAME} from ${#TARGET_DIRS[@]} location(s)"
else
    echo "linked ${PLUGIN_NAME} into ${#TARGET_DIRS[@]} location(s)"
fi
