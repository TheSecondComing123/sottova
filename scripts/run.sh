#!/bin/bash
set -e
cd "$(dirname "$0")/.."
scripts/bundle.sh debug
codesign -f -s - .build/debug/Sottova.app
pkill -x Sottova || true
open ${SOTTOVA_TEST_FILE:+--env "SOTTOVA_TEST_FILE=$SOTTOVA_TEST_FILE"} .build/debug/Sottova.app
