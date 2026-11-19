#!/bin/zsh
# Removes the router, the punctuation helper and the accurate pass, and puts Handy back on its own paste (Cmd+V) and
# the default mic. Handy stays installed (drag it to the Trash if you want). Your word list is kept.
support="$HOME/Library/Application Support/handy-router"
settings="$HOME/Library/Application Support/com.pais.handy/settings_store.json"
for prefix in local.dictation local.axel; do
  for name in handy-router handy-punctuate handy-accurate; do
    launchctl bootout "gui/$(id -u)/$prefix.$name" 2>/dev/null
    rm -f "$HOME/Library/LaunchAgents/$prefix.$name.plist"
  done
done
rm -rf "$HOME/Applications/Handy Router.app"
osascript -e 'quit app "Handy"' >/dev/null 2>&1
for _ in {1..50}; do pgrep -f "/Applications/Handy.app/Contents/MacOS/" >/dev/null || break; sleep 0.1; done
if [[ -f "$settings" ]]; then
  /usr/bin/python3 - "$settings" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
s = doc.get("settings", doc)
s["paste_method"] = "ctrl_v"
s["external_script_path"] = None
if s.get("selected_microphone") == "Handy Mics":
    s["selected_microphone"] = None
json.dump(doc, open(path, "w", encoding="utf-8"), indent=2)
PY
fi
find "$support" -mindepth 1 -maxdepth 1 ! -name vocabulary.txt -exec rm -rf {} + 2>/dev/null
open -a /Applications/Handy.app 2>/dev/null
echo "Removed. Handy pastes with Cmd+V again. Your word list is still in $support/vocabulary.txt."
echo "The \"Handy Mics\" device stays in Audio MIDI Setup; delete it there if you want."
