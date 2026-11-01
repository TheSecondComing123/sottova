#!/bin/bash
# Shoots one window of the isolated copy, then quits it. Nothing it runs can reach real data, wakes or sound.
# Usage: scripts/harness.sh <scratch-path> <state> <out.png> [-palette gruvbox] [-shotRoute alarms] [-shotWidth 855] [-shotAppearance light] [-shotMenuAt 700,356] [-shotStatusMenu YES]
# States: the list in Controller.shotEnter. EXTRA_SWIFT=-DNEWLOOK builds the new look.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scratch=$1 state=$2 out=$3
shift 3
app="$scratch/SottovaShot.app"
plist="$app/Contents/Info.plist"
buddy=/usr/libexec/PlistBuddy

# CONFIG=release for measuring
config=${CONFIG:-debug}
swift build -c "$config" --scratch-path "$scratch" -Xswiftc -DSHOT ${EXTRA_SWIFT:+-Xswiftc $EXTRA_SWIFT} >&2
rm -rf "${app:?}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$scratch/$config/Sottova" "$app/Contents/MacOS/SottovaShot"
cp Support/Info.plist "$plist"
cp Support/AppIcon.icns "$app/Contents/Resources/"
cp -R Support/Icons "$app/Contents/Resources/"
cp -R Support/Themes "$app/Contents/Resources/"
$buddy -c "Delete :CFBundleURLTypes" -c "Set :CFBundleExecutable SottovaShot" -c "Set :CFBundleName SottovaShot" \
    -c "Set :CFBundleIdentifier com.alanbagel.sottova.shot" "$plist"
codesign -f -s - "$app" 2>/dev/null

world() {
    pmset -g sched
    stat -f '%m' "$HOME/Library/Application Support/Sottova/alarms.json"
    stat -f '%m' "$HOME/Music"
    pgrep -x Sottova || true
}
storage=$(mktemp -d "${TMPDIR:-/private/tmp}/sottova-shot.XXXXXX")
stop() {
    pkill -x SottovaShot || true
    [[ -n "${TICKS:-}" && -f "$storage/ticks" ]] && cp "$storage/ticks" "$TICKS"
    rm -rf "${storage:?}"
}
trap stop EXIT
check() {
    if [[ "$(world)" != "$before" ]]; then
        echo "the real world changed while the copy ran: stopping it" >&2
        diff <(echo "$before") <(world) >&2 || true
        exit 1
    fi
}
if pgrep -qx SottovaShot; then echo "a copy is already running" >&2; exit 1; fi
before=$(world)
defaults delete com.alanbagel.sottova.shot 2>/dev/null || true

# copied here because the copy reading ~/Documents itself makes macOS ask the owner again after every build
# MINE=1 with state mine: the owner's own names, covers and rows, over silence
[[ -n "${MINE:-}" ]] && python3 scripts/harness-mine.py "$storage"
covers=(); [[ -d notes/design/covers ]] && ditto notes/design/covers "$storage/covers" && covers=(-shotCovers "$storage/covers")
# -g: never takes focus from whatever the owner is doing. App Nap stops a silent app in the background from ticking
open -g -n --env SOTTOVA_SHOT_STORAGE="$storage" "$app" --args -NSAppSleepDisabled YES -shotState "$state" ${covers[@]+"${covers[@]}"} "$@"
for _ in {1..120}; do
    [[ -s "$storage/ready" ]] && break
    pgrep -qx SottovaShot || { sleep 0.5; pgrep -qx SottovaShot || { echo "the copy exited" >&2; exit 1; }; }
    check
    sleep 0.25
done
[[ -s "$storage/ready" ]] || { echo "no window after 30 s" >&2; exit 1; }
check
screencapture -x -o -l "$(cat "$storage/ready")" "$out"
# KEEP=1: leave it up to be watched, still checked, until you quit it or press ctrl-c
if [[ -n "${KEEP:-}" ]]; then
    while pgrep -qx SottovaShot; do check; sleep 2; done
fi
pkill -x SottovaShot || true
for _ in {1..40}; do pgrep -qx SottovaShot || break; sleep 0.25; done
check
if pgrep -qx SottovaShot; then echo "the copy won't quit" >&2; exit 1; fi
echo "$out"
