#!/bin/bash
set -e
cd "$(dirname "$0")/.."
swift build
rm -rf .build/Sottova.app
mkdir -p .build/Sottova.app/Contents/MacOS
cp .build/debug/Sottova .build/Sottova.app/Contents/MacOS/
cp Support/Info.plist .build/Sottova.app/Contents/
codesign -f -s - .build/Sottova.app
pkill -x Sottova || true
open ${SOTTOVA_TEST_FILE:+--env "SOTTOVA_TEST_FILE=$SOTTOVA_TEST_FILE"} .build/Sottova.app
