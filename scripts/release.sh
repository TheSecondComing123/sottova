#!/bin/bash
# Release build, signed and zipped into .build/release/Sottova-<version>.zip.
#   SOTTOVA_SIGN_ID   Developer ID Application identity; without it the build is ad-hoc signed and only runs here
#   SOTTOVA_NOTARY    notarytool keychain profile (xcrun notarytool store-credentials); needs SOTTOVA_SIGN_ID
set -e
cd "$(dirname "$0")/.."
scripts/bundle.sh release
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)
zip=".build/release/Sottova-$version.zip"

if [ -n "$SOTTOVA_SIGN_ID" ]; then
    codesign -f --options runtime --timestamp -s "$SOTTOVA_SIGN_ID" .build/release/Sottova.app
else
    echo "no SOTTOVA_SIGN_ID, so ad-hoc signing: this build won't open on other Macs"
    codesign -f -s - .build/release/Sottova.app
fi
codesign --verify --strict .build/release/Sottova.app

rm -f "$zip"
ditto -c -k --keepParent .build/release/Sottova.app "$zip"

if [ -n "$SOTTOVA_NOTARY" ]; then
    [ -n "$SOTTOVA_SIGN_ID" ] || { echo "notarization needs a Developer ID signature, set SOTTOVA_SIGN_ID"; exit 1; }
    # --wait exits 0 even when Apple rejects the build, so read the verdict
    result=$(xcrun notarytool submit "$zip" --keychain-profile "$SOTTOVA_NOTARY" --wait --output-format json)
    status=$(/usr/bin/plutil -extract status raw -o - - <<< "$result")
    if [ "$status" != "Accepted" ]; then
        echo "notarization: $status"
        xcrun notarytool log "$(/usr/bin/plutil -extract id raw -o - - <<< "$result")" --keychain-profile "$SOTTOVA_NOTARY"
        exit 1
    fi
    xcrun stapler staple .build/release/Sottova.app
    xcrun stapler validate .build/release/Sottova.app
    spctl -a -vvv -t exec .build/release/Sottova.app
    # re-zip so the download carries the stapled ticket
    rm -f "$zip"
    ditto -c -k --keepParent .build/release/Sottova.app "$zip"
fi
echo "$zip"
