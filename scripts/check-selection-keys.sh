#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scratch=$(mktemp -d "${TMPDIR:-/private/tmp}/sottova-selection-keys.XXXXXX")
trap 'rm -rf "${scratch:?}"' EXIT
swiftc -module-cache-path "${CLANG_MODULE_CACHE_PATH:-$scratch/modules}" -parse-as-library Sources/Sottova/SelectionKeys.swift Tests/SottovaAppChecks/SelectionKeysCheck.swift -o "$scratch/check"
"$scratch/check"
