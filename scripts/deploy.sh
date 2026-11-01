#!/bin/zsh
# Puts a pinned commit in place of the running app, keeping what it replaced.
#   deploy.sh --archive [name]    keeps the current bundle and state, changing nothing else
#   deploy.sh <commit>            builds it apart from the live build folder, then swaps it in
#   deploy.sh --rollback [name]   restores a kept bundle, alarms.json and library.json; newest if unnamed
# Rehearsal: SOTTOVA_DEPLOY_TEST=<folder with state/ and live/> SOTTOVA_DEPLOY_BUILT=<bundle> SOTTOVA_DEPLOY_NOW=HH:MM
# work on that folder and a test app instead.
set -e
repo=${0:A:h:h}
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

if [[ -n $SOTTOVA_DEPLOY_TEST ]]; then
    state=$SOTTOVA_DEPLOY_TEST/state app=$SOTTOVA_DEPLOY_TEST/live/SpikeApp.app
    id=com.alanbagel.sottova.spike proc=SottovaSpike
else
    state="$HOME/Library/Application Support/Sottova"
    # the guard opens this path
    app=$repo/.build/arm64-apple-macosx/release/Sottova.app
    id=com.alanbagel.sottova proc=Sottova
fi
archive=$state/archive
kept=(alarms.json library.json profile.json resume.json status.json)

die() { print -ru2 -- "deploy: $1"; exit 1; }

# prints why not, if now is near a wake or within 10 minutes after an alarm
refuse_now() {
    /usr/bin/python3 - "$state/alarms.json" "$SOTTOVA_DEPLOY_NOW" <<'PY'
import datetime, json, sys
now = datetime.datetime.now()
if sys.argv[2]:
    h, m = sys.argv[2].split(":")
    now = now.replace(hour=int(h), minute=int(m))
t = now.hour * 60 + now.minute
if 6 * 60 + 30 <= t < 7 * 60 + 30: print("too close to Lauds (06:30-07:30)")
elif 19 * 60 + 30 <= t < 21 * 60 + 15: print("too close to Compline (19:30-21:15)")
else:
    try: alarms = json.load(open(sys.argv[1]))
    except Exception as e: print(f"can't read alarms.json: {e}"); sys.exit()
    weekday = now.isoweekday() % 7 + 1
    for a in alarms:
        due = a["hour"] * 60 + a["minute"]
        if a.get("on", True) and (not a.get("weekdays") or weekday in a["weekdays"]) and 0 <= t - due < 10:
            print(f"{a.get('name')} went off under 10 minutes ago")
PY
}

quit_app() {
    osascript -e "quit app id \"$id\"" 2>/dev/null || true
    for _ in {1..40}; do pgrep -qx $proc || return 0; /bin/sleep 0.25; done
    die "$proc didn't quit (a sheet open?); nothing changed"
}

launch() {
    open -g "$app"
    for _ in {1..40}; do pgrep -qx $proc && break; /bin/sleep 0.25; done
    pgrep -qx $proc || die "$proc didn't start from $app"
    print -r -- "running: $(ps -o command= -p $(pgrep -x $proc))"
}

keep() {
    mkdir -p "$archive/$1"
    for f in $kept; do [[ -e $state/$f ]] && /bin/cp -f "$state/$f" "$archive/$1/"; done
    return 0
}

case $1 in
--archive)
    name=${2:-live-pre}
    [[ -e $archive/$name ]] && die "$name is already kept"
    keep "$name"
    ditto "$app" "$archive/$name/app.app"
    print -r -- "kept: $archive/$name"
    ;;
--rollback)
    [[ -d $archive ]] || die "nothing kept"
    name=${2:-$(command ls -t "$archive" | head -1)}
    [[ -d $archive/$name/app.app ]] || die "no bundle kept in $name"
    why=$(refuse_now); [[ -z $why ]] || die "$why"
    quit_app
    mkdir -p "$archive/before-rollback-$$"
    mv "$app" "$archive/before-rollback-$$/app.app"
    keep "before-rollback-$$"
    ditto "$archive/$name/app.app" "$app"
    for f in alarms.json library.json; do [[ -e $archive/$name/$f ]] && /bin/cp -f "$archive/$name/$f" "$state/$f"; done
    launch
    print -r -- "restored $name; an old build drops lastFired and partSpent, and can set a library with -inf aside"
    ;;
""|-*)
    print -ru2 -- "usage: deploy.sh <commit> | --archive [name] | --rollback [name]"; exit 2
    ;;
*)
    sha=$(git -C "$repo" rev-parse --short "$1^{commit}")
    why=$(refuse_now); [[ -z $why ]] || die "$why"
    if [[ -n $SOTTOVA_DEPLOY_BUILT ]]; then
        built=$SOTTOVA_DEPLOY_BUILT
    else
        tree=$repo/../sottova-deploy-$sha
        git -C "$repo" worktree add --detach "$tree" "$sha"
        "$tree/scripts/bundle.sh" release
        built=$tree/.build/release/Sottova.app
        codesign -f -s - "$built"
        codesign --verify --strict "$built"
    fi
    # the build may have taken a while
    why=$(refuse_now); [[ -z $why ]] || die "$why"
    quit_app
    name=before-$sha-$(date +%m%d-%H%M)
    keep "$name"
    mv "$app" "$archive/$name/app.app"
    ditto "$built" "$app" || { mv "$archive/$name/app.app" "$app"; launch; die "couldn't copy the new build; the old one is back"; }
    launch
    if [[ -z $SOTTOVA_DEPLOY_BUILT ]]; then
        git -C "$repo" tag -f "live-$sha" "$sha"
        git -C "$repo" worktree remove --force "$tree"
    fi
    print -r -- "deployed $sha; kept the old one as $name"
    pmset -g sched | sed -n 2,4p
    ;;
esac
