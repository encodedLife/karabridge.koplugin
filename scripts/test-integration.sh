#!/usr/bin/env bash
#
# Run KaraBridge's tests against a real Karakeep server.
#
# These are opt-in and must never run by accident against a production
# instance. Three environment variables gate them:
#
#   KARABRIDGE_TEST_SERVER_URL     base address, without /api/v1
#   KARABRIDGE_TEST_API_TOKEN      an API key created for testing only
#   KARABRIDGE_TEST_ALLOW_WRITES   set to 1 to permit anything that creates,
#                                  updates or deletes. Read-only checks run
#                                  without it.
#
# Optional:
#   KARABRIDGE_TEST_LIST           name of a list to confine writes to
#
# Every object the tests create is titled with the "[KaraBridge Test]" prefix
# and removed afterwards. Nothing without that prefix is ever touched.
#
# Put the variables in spec/integration/.env (gitignored) or export them:
#
#   KARABRIDGE_TEST_SERVER_URL=https://karakeep.test.example.org \
#   KARABRIDGE_TEST_API_TOKEN=ak1_... \
#   KARABRIDGE_TEST_ALLOW_WRITES=1 \
#     scripts/test-integration.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${REPO_ROOT}"

ENV_FILE="spec/integration/.env"
if [[ -f "${ENV_FILE}" ]]; then
    echo "reading ${ENV_FILE}"
    # shellcheck disable=SC1090
    set -a && source "${ENV_FILE}" && set +a
fi

if [[ -z "${KARABRIDGE_TEST_SERVER_URL:-}" || -z "${KARABRIDGE_TEST_API_TOKEN:-}" ]]; then
    cat >&2 <<'EOF'
Integration tests are opt-in and were skipped.

Set at least:
  KARABRIDGE_TEST_SERVER_URL
  KARABRIDGE_TEST_API_TOKEN

Use a Karakeep instance and an API key created for testing. Do not point these
at an instance holding bookmarks you care about.
EOF
    exit 0
fi

# Never echoed: the token is the one thing these variables carry that matters.
echo "server:      ${KARABRIDGE_TEST_SERVER_URL}"
echo "token:       (set, ${#KARABRIDGE_TEST_API_TOKEN} chars)"
echo "write tests: ${KARABRIDGE_TEST_ALLOW_WRITES:-0}"

if [[ "${KARABRIDGE_TEST_ALLOW_WRITES:-0}" != "1" ]]; then
    echo "note: writes are disabled; only read-only checks will run" >&2
fi

# Only the API specs; plugin_loading_spec belongs to scripts/test-koreader.sh
# and needs busted's environment rather than this one.
SPECS=(spec/integration/karakeep_api_spec.lua)

if [[ ! -f "${SPECS[0]}" ]]; then
    echo "no integration specs exist yet" >&2
    exit 0
fi

# These make real HTTP requests, so they need luasocket. A plain lua5.1 rarely
# has it; KOReader ships it, so a built emulator is the interpreter of choice.
KOREADER_ROOT="${KARABRIDGE_KOREADER:-}"

EMULATOR=""
for candidate in "${KOREADER_ROOT}"/koreader-emulator-*/koreader; do
    if [[ -x "${candidate}/luajit" ]]; then
        EMULATOR="${candidate}"
        break
    fi
done

if [[ -z "${EMULATOR}" ]]; then
    cat >&2 <<EOF
No built KOReader was found under:
  ${KOREADER_ROOT}

These specs make real HTTP requests and need luasocket, which KOReader ships
and a plain lua5.1 usually does not. Build one with:
  cd ${KOREADER_ROOT} && ./kodev build

Or point KARABRIDGE_KOREADER at an existing tree.
EOF
    exit 1
fi

echo "interpreter: ${EMULATOR}/luajit"
echo "+ luajit spec/support/run_unit.lua ${SPECS[*]}"

# KOReader's own module paths, so socket/ltn12/socketutil resolve, plus the
# plugin and the repository root for the specs themselves.
exec env -C "${EMULATOR}" \
    KO_HOME="${EMULATOR}/spec/run" \
    LUA_PATH="?.lua;common/?.lua;frontend/?.lua;spec/front/unit/?.lua;${REPO_ROOT}/karabridge.koplugin/?.lua;${REPO_ROOT}/?.lua;;" \
    LUA_CPATH="?.so;common/?.so;libs/?.so;;" \
    ./luajit "${REPO_ROOT}/spec/support/run_unit.lua" \
    "${REPO_ROOT}/${SPECS[0]}"
