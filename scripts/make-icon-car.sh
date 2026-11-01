#!/bin/bash
# Compiles Support/Sottova.icon, made to open in Icon Composer, to Support/Assets.car.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
out=$(mktemp -d)
xcrun actool Support/Sottova.icon --compile "$out" --app-icon Sottova --enable-on-demand-resources NO --development-region en \
    --target-device mac --platform macosx --minimum-deployment-target 26.0 --output-partial-info-plist "$out/partial.plist" >/dev/null
cp "$out/Assets.car" Support/Assets.car
rm -rf "${out:?}"
