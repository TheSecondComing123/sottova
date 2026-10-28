# sottova

sottova plays your own music the way Minecraft plays its soundtrack. each track rises out of silence, falls back into it, and then there's quiet for a while before the next one. you pick how long the quiet lasts.

silence is the point, not a bug. a playlist that never stops turns into wallpaper. a track that shows up after ten minutes of nothing gets heard.

it lives in the menu bar and stays out of the way.

## what it does

- plays any folders of local music (mp3, aac, alac, flac, wav, aiff and ogg) and watches them for new files
- fades every track in from silence and back out, then waits a random gap between your shortest and longest
- levels every track to the same loudness (−18 LUFS, peaks under −1 dBTP), measured once per file with [libebur128](https://github.com/jiixyj/libebur128)
- shuffles without repeats: every track plays once before any repeats, and never one of the last 10
- keeps the Mac awake during gaps (the audio engine is off then, so nothing else would), pauses on sleep and resumes after
- shows up in Now Playing, and the media keys work

## presets

| preset | gap | fade in / out |
| --- | --- | --- |
| Minecraft | 10–20 min | 6 s / 8 s |
| Sparse | 3–8 min | 6 s / 8 s |
| Short | 30 s–2 min | 4 s / 6 s |
| Continuous | none, 4 s equal-power crossfade | 3 s / 3 s |

Minecraft's own delay between overworld tracks is 10 to 20 minutes. change anything and the preset becomes Custom.

## build it

needs macOS 26 and Xcode 26.

```sh
scripts/run.sh        # debug build, opens from the menu bar
scripts/release.sh    # release zip in .build/release
```

`release.sh` signs with a Developer ID when `SOTTOVA_SIGN_ID` is set and notarizes when `SOTTOVA_NOTARY` names a `notarytool` keychain profile. without them the build only runs on the Mac that built it.

`swift test` runs the engine headless: the state machine, offline renders of the audio graph, and the EBU Tech 3341 loudness signals.

## scripting

links, for hotkey tools and Raycast:

```
sottova://play
sottova://pause
sottova://toggle
sottova://skip
sottova://preset/minecraft
```

every state change rewrites `~/Library/Application Support/Sottova/status.json`:

```json
{"preset":"Short","status":"resting","title":"clip2","nextTrackAt":"2026-10-28T16:42:10Z"}
```

and posts the same thing as the distributed notification `com.alanbagel.sottova.status`. for SketchyBar:

```sh
sketchybar --add event sottova_status com.alanbagel.sottova.status \
           --subscribe sottova sottova_status
```

## files

everything sits in `~/Library/Application Support/Sottova`, as plain files:

- `library.json`: watched folders and the loudness of every file
- `profile.json`: the current profile, schema 1
- `plays.jsonl`: one line per track played, with the gap after it
- `status.json`: the current state

nothing leaves your Mac. there's no account, no analytics, and no network access.

## what it isn't

sottova is a music player. it makes no claims about sleep, focus, stress or health.
