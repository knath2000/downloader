#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LUSTRECLI_ROOT="${LUSTRECLI_ROOT:-${ROOT}/../pmvhavencli}"
APP_PATH="${1:?Usage: embed-lustre-agent-runtime.sh /path/to/LustreStudio.app}"
PINNED_REVISION="$(tr -d '[:space:]' < "${ROOT}/LUSTRECLI_REVISION")"
CURRENT_REVISION="$(git -C "${LUSTRECLI_ROOT}" rev-parse HEAD)"

if [[ "${CURRENT_REVISION}" != "${PINNED_REVISION}" ]]; then
    echo "ERROR: lustrecli is at ${CURRENT_REVISION}; expected ${PINNED_REVISION}." >&2
    exit 1
fi
if ! git -C "${LUSTRECLI_ROOT}" diff --quiet -- Sources Package.swift Package.resolved ||
   ! git -C "${LUSTRECLI_ROOT}" diff --cached --quiet -- Sources Package.swift Package.resolved; then
    echo "ERROR: lustrecli has uncommitted source changes; release artifacts must come from the pinned revision exactly." >&2
    exit 1
fi

swift build --package-path "${LUSTRECLI_ROOT}" -c release

BIN_PATH="$(swift build --package-path "${LUSTRECLI_ROOT}" -c release --show-bin-path)"
RUNTIME_PATH="${APP_PATH}/Contents/Resources/LustreAgentRuntime"
rm -rf "${RUNTIME_PATH}"
mkdir -p "${RUNTIME_PATH}"

for item in lustre-agent lustre-browser-bridge lustre-auth-helper LustreAgent_LustreAgent.bundle; do
    if [[ ! -e "${BIN_PATH}/${item}" ]]; then
        echo "ERROR: Missing Agent runtime item ${BIN_PATH}/${item}" >&2
        exit 1
    fi
    cp -R "${BIN_PATH}/${item}" "${RUNTIME_PATH}/"
done

if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
    for executable in lustre-agent lustre-browser-bridge lustre-auth-helper; do
        codesign --force --options runtime --timestamp --sign "${CODE_SIGN_IDENTITY}" "${RUNTIME_PATH}/${executable}"
    done
    codesign --force --options runtime --timestamp --sign "${CODE_SIGN_IDENTITY}" "${APP_PATH}"
fi
