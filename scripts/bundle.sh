#!/bin/bash
# Builds and wraps the binary into .build/<config>/Sottova.app. Usage: scripts/bundle.sh [debug|release]
set -e
cd "$(dirname "$0")/.."
config=${1:-debug}
swift build -c "$config"
rm -rf ".build/$config/Sottova.app"
mkdir -p ".build/$config/Sottova.app/Contents/MacOS" ".build/$config/Sottova.app/Contents/Resources"
cp ".build/$config/Sottova" ".build/$config/Sottova.app/Contents/MacOS/"
cp Support/Info.plist ".build/$config/Sottova.app/Contents/"
cp Support/AppIcon.icns Support/Assets.car ".build/$config/Sottova.app/Contents/Resources/"
cp -R Support/Icons ".build/$config/Sottova.app/Contents/Resources/"
cp -R Support/Themes ".build/$config/Sottova.app/Contents/Resources/"
