#!/usr/bin/env bash
#
# Build a release zip and, optionally, publish it as a GitHub release.
#
# The zip is what the in-plugin updater downloads and unpacks, so its shape is
# load-bearing: exactly one top-level directory, `karabridge.koplugin/`, which
# `Device:unpackArchive(..., with_stripped_root = true)` strips on the way out.
#
#   scripts/release.sh              build the zip only
#   scripts/release.sh --publish    also create the GitHub release
#
# The version comes from karabridge.koplugin/_meta.lua and nowhere else. The
# tag is that version with a leading v.
set -euo pipefail

cd "$(dirname "$0")/.."

version="$(sed -n 's/.*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' karabridge.koplugin/_meta.lua | head -1)"
if [ -z "$version" ]; then
    echo "could not read the version from _meta.lua" >&2
    exit 1
fi

tag="v${version}"
out="dist/karabridge-${version}.zip"

echo "== KaraBridge ${version} (${tag})"

# A release that fails its own tests is not a release.
echo "== checks"
scripts/check.sh > /dev/null
echo "== unit tests"
scripts/test-unit.sh > /dev/null
echo "   passed"

rm -rf dist
mkdir -p dist

# A user's own configuration must never be shipped: it holds an API key, and
# karabridge.conf is gitignored precisely so this cannot happen by accident.
if [ -e karabridge.koplugin/karabridge.conf ]; then
    echo "refusing to package: karabridge.koplugin/karabridge.conf exists" >&2
    exit 1
fi

zip -qr "$out" karabridge.koplugin -x '*.DS_Store' -x '*/.*'
echo "== built $out ($(du -h "$out" | cut -f1))"

# Prove the archive is the shape the updater expects, rather than finding out
# on a device.
#
# The listing is captured once rather than piped into grep twice: `grep -q`
# exits on the first match, unzip then dies of SIGPIPE, and `pipefail` reports
# the whole pipeline as failed -- so the check failed precisely when it should
# have passed.
listing="$(unzip -l "$out")"
for required in _meta.lua main.lua; do
    case "$listing" in
        *"karabridge.koplugin/$required"*) ;;
        *)
            echo "the zip has no karabridge.koplugin/$required" >&2
            exit 1
            ;;
    esac
done
echo "== archive shape verified"

# Install the zip into a throwaway directory, with a configuration inside the
# old copy -- the case 0.0.2 crashed on. Checking the shape of the archive is
# not the same as checking that it installs, and the difference cost a version
# number.
repo="$PWD"
zip_abs="$repo/$out"

# Every usable KOReader that can be found, not just the first. The bug that
# made 0.0.5 necessary was an extraction call missing from older KOReader, and
# the test skipped those trees -- so which build happened to be found first
# decided whether the gap was visible. Checking all of them removes the luck.
tested=0
failed=0

# Set KARABRIDGE_KOREADER to a KOReader checkout to have the archive's
# installation verified before it is published.
for candidate in "${KARABRIDGE_KOREADER:-}"/koreader-emulator-*/koreader \
                 "${KARABRIDGE_KOREADER:-}"; do
    [ -x "$candidate/luajit" ] || continue

    echo "== install smoke test ($candidate)"
    smoke_home="$(mktemp -d)"

    # errexit off around the pipeline: with pipefail on, a candidate that
    # cannot start would abort the whole script instead of letting the loop try
    # the next one.
    set +e
    ( cd "$candidate" && KO_HOME="$smoke_home" ./luajit "$repo/scripts/install-smoke.lua" \
        "$zip_abs" "$candidate" "$repo" ) 2>&1 \
        | grep -vE "^ffi\.|^lib_|^has mono|ERROR #! Font|INFO |Starting SDL"
    smoke_status="${PIPESTATUS[0]}"
    set -e

    rm -rf "$smoke_home"

    case "$smoke_status" in
        0) tested=$((tested + 1)) ;;
        2) echo "   (that build cannot run the test; skipped)" ;;
        *) failed=$((failed + 1)) ;;
    esac
done

if [ "$failed" -gt 0 ]; then
    echo "refusing to publish: the archive does not install on $failed KOReader build(s)" >&2
    exit 1
fi

if [ "$tested" -eq 0 ]; then
    echo
    echo "!! No usable KOReader build found, so the install smoke test was SKIPPED." >&2
    echo "!! This archive has NOT been shown to install. Publishing it is a guess." >&2
    echo
else
    echo "== installs on $tested KOReader build(s)"
fi

if [ "${1:-}" != "--publish" ]; then
    echo
    echo "Not published. Run with --publish to create the GitHub release."
    exit 0
fi

if ! command -v gh > /dev/null; then
    echo "gh is not installed; publish by hand or install the GitHub CLI" >&2
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "refusing to publish with uncommitted changes" >&2
    exit 1
fi

git tag -a "$tag" -m "KaraBridge $version" 2>/dev/null || echo "== tag $tag already exists"
git push origin "$tag"

gh release create "$tag" "$out" \
    --title "KaraBridge $version" \
    --notes "See CHANGELOG.md for what changed."

echo "== published $tag"
