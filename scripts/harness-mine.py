#!/usr/bin/env python3
"""Fills the copy's temp folder with the owner's library, read here so the copy never touches the real one: real
names, covers, playlists and rows, over silent files that take no disk."""
import json, os, re, shutil, struct, sys

# resolved as the copy resolves it, or rows don't match their playlists
root = os.path.realpath(sys.argv[1])
home = os.path.expanduser("~")
real_music = f"{home}/Music"
music = f"{root}/Music"
storage = f"{root}/Application Support"
support = f"{home}/Library/Application Support/Sottova"
RATE = 8000

def moved(path):
    return re.sub(r"\.(flac|mp3|m4a|aac|aiff?|ogg|opus|wav)$", ".wav", path.replace(real_music, music, 1))

library = json.load(open(f"{support}/library.json"))
library["folders"] = []
entries = {}
for path, entry in library["entries"].items():
    target = moved(path)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    data = int((entry.get("meta") or {}).get("duration") or 1) * RATE * 2
    with open(target, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + data) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE * 2, 2, 16)
                + b"data" + struct.pack("<I", data))
        # sparse: zeros are silence and use no disk
        f.truncate(44 + data)
    # playlists read their songs through standardizedFileURL, which drops /private from a temp path
    entries[target.removeprefix("/private")] = entry
library["entries"] = entries
os.makedirs(storage, exist_ok=True)
json.dump(library, open(f"{storage}/library.json", "w"))

playlists = f"{real_music}/Sottova Playlists"
os.makedirs(f"{music}/Sottova Playlists", exist_ok=True)
for name in os.listdir(playlists):
    source, target = f"{playlists}/{name}", f"{music}/Sottova Playlists/{name}"
    if name.endswith(".m3u8"):
        text = open(source, encoding="utf-8").read().replace(real_music, music)
        open(target, "w", encoding="utf-8").write("\n".join(
            line if line.startswith("#") else re.sub(r"\.(flac|mp3|m4a|aac|aiff?|ogg|opus)$", ".wav", line)
            for line in text.split("\n")))
    else:
        shutil.copy(source, target)

alarms = json.load(open(f"{support}/alarms.json"))
for alarm in alarms:
    alarm["source"] = alarm["source"].replace(real_music, music)
    # a row minding the calendar would ask this copy for calendar access
    alarm["heedsCalendar"] = False
json.dump(alarms, open(f"{storage}/alarms.json", "w"))

shutil.copy(f"{support}/profile.json", storage)
shutil.copytree(f"{home}/Library/Caches/Sottova/Artwork", f"{root}/Artwork", dirs_exist_ok=True)
