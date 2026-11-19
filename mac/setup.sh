#!/bin/zsh
# Sets up dictation on a Mac: Handy (tap Fn, talk, tap Fn), its live model, the router (the text lands in the app you
# started in, or stays on the clipboard), punctuation, and the accurate pass (Whisper, told your words, while you talk).
# Re-run it any time to update; your word list and settings are kept.
#
#   git clone https://github.com/AxelTTa/dictation.git ~/dictation && zsh ~/dictation/mac/setup.sh
#
#   --ci   tests: opens no windows at the end
#   DICTATION_WHISPER=turbo zsh setup.sh   the smaller Whisper (Large v3 Turbo, 0.6 GB; the default on Intel Macs)
# Needs macOS 13+ (Apple Silicon recommended), about 3 GB of disk, and an admin account (Handy goes in /Applications).
set -e
here="${0:A:h}"
cd "$here"
ci=0
[[ "$1" == --ci ]] && ci=1
handy_version=0.9.8
data="$HOME/Library/Application Support/com.pais.handy"
settings="$data/settings_store.json"
step() { print -P "\n%F{cyan}== $1%f" }
fetch() {  # fetch <url> <dest> <sha256>: skips a file already there and checked
  [[ -f "$2" && $(shasum -a 256 "$2" | cut -d' ' -f1) == "$3" ]] && return
  mkdir -p "${2:h}"
  echo "   downloading ${2:t}"
  curl -fL --retry 3 --progress-bar -o "$2.part" "$1"
  [[ $(shasum -a 256 "$2.part" | cut -d' ' -f1) == "$3" ]] || { rm -f "$2.part"; echo "checksum mismatch for $1"; exit 1; }
  mv "$2.part" "$2"
}

print -P "%F{green}Dictation setup for macOS (Handy $handy_version + router + punctuation + accurate pass)%f"

step "Command line tools (Swift and Python)"
if ! xcode-select -p >/dev/null 2>&1 || ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
  xcode-select --install 2>/dev/null || true
  echo "A window opened to install Apple's command line tools. Click Install, wait for it to finish, then run this again."
  exit 1
fi
echo "   ok"

step "Handy $handy_version"
if [[ ! -d /Applications/Handy.app ]]; then
  if [[ $(uname -m) == arm64 ]]; then
    dmg=Handy_${handy_version}_aarch64.dmg sum=81ac05aaaf4fafa62826bb40c5cf0bc0c813fb6fc8255497480e762620779417
  else
    dmg=Handy_${handy_version}_x64.dmg sum=03b3edb44eef448187643c40af8626202881374f952c9cc3039848ff6f9c1b1b
  fi
  tmp=$(mktemp -d)
  fetch "https://github.com/cjpais/Handy/releases/download/v$handy_version/$dmg" "$tmp/$dmg" $sum
  mnt=$(hdiutil attach -nobrowse -readonly "$tmp/$dmg" | awk -F'\t' '/\/Volumes\// {print $NF}' | tail -1)
  ditto "$mnt/Handy.app" /Applications/Handy.app || { hdiutil detach "$mnt" -quiet; echo "Could not copy Handy to /Applications (admin account needed)."; exit 1; }
  hdiutil detach "$mnt" -quiet
  rm -rf "$tmp"
  echo "   installed"
else
  v=$(defaults read /Applications/Handy.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo "?")
  [[ $v == $handy_version ]] && echo "   already installed" ||
    print -P "   %F{yellow}Handy $v is installed; this setup was tested with $handy_version. If dictation misbehaves: https://github.com/cjpais/Handy/releases/tag/v$handy_version%f"
fi

step "Live model (Parakeet, 0.7 GB the first time)"
live=parakeet-unified-en-0.6b-Q8_0.gguf
fetch "https://huggingface.co/handy-computer/parakeet-unified-en-0.6b-gguf/resolve/7e948f21b7bdbac698d3318db9d350f1096f3b6c/$live" \
  "$data/models/$live" 4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795
echo "   ok"

step "Handy's settings"
# Handy keeps its settings in memory and writes them back, so it is closed while they change.
osascript -e 'quit app "Handy"' >/dev/null 2>&1 || true
for _ in {1..50}; do pgrep -f "/Applications/Handy.app/Contents/MacOS/" >/dev/null || break; sleep 0.1; done
pkill -f "/Applications/Handy.app/Contents/MacOS/" 2>/dev/null || true
mkdir -p "$data"
/usr/bin/python3 - "$settings" "handy-computer/parakeet-unified-en-0.6b-gguf/$live" <<'PY'
import json, os, shutil, sys
path, model = sys.argv[1], sys.argv[2]
doc = {}
if os.path.exists(path):
    shutil.copyfile(path, path + ".bak-last-dictation-setup")
    if not os.path.exists(path + ".bak-before-dictation"):
        shutil.copyfile(path, path + ".bak-before-dictation")
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
s = doc.setdefault("settings", {})
fresh = not s
s.update({
    "selected_model": model,             # Parakeet: transcribes while you talk, so the text is there right after Fn
    "overlay_style": "minimal",          # the recording pill only, no words on screen while you talk
    "word_correction_threshold": 0.05,   # custom words: join exact split-ups only, never rewrite ordinary words
    "hold_threshold_ms": 1000,           # a quick tap is a tap even when the model takes 0.3 s to start
    "update_checks_enabled": False,      # this setup is tested with one Handy version
    "autostart_enabled": True,
})
if fresh:
    s["onboarding_completed"] = True     # Handy still asks for Microphone and Accessibility when it opens
def binding(id_, name, desc, default, current=None):
    return {"id": id_, "name": name, "description": desc, "default_binding": default, "current_binding": current or default}
b = s.get("bindings")
if not b:
    s["bindings"] = {
        "transcribe": binding("transcribe", "Transcribe", "Converts your speech into text.", "option+space", "fn"),
        "transcribe_with_post_process": binding("transcribe_with_post_process", "Transcribe with Post-Processing",
            "Converts your speech into text and applies AI post-processing.", "option+shift+space"),
        "cancel": binding("cancel", "Cancel", "Cancels the current recording.", "escape", "shift+escape"),
    }
elif b.get("transcribe", {}).get("current_binding") == "option+space":
    b["transcribe"]["current_binding"] = "fn"   # only if it was never changed from Handy's default
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
os.replace(tmp, path)
print("   shortcut: " + s["bindings"]["transcribe"]["current_binding"] + ", live model: Parakeet, overlay: minimal")
PY

step "Router, punctuation and accurate pass (about 1.4 GB the first time)"
zsh build.sh install

open -a /Applications/Handy.app
vocab="$HOME/Library/Application Support/handy-router/vocabulary.txt"
step "Done"
cat <<E
Tap Fn, talk, tap Fn again: the text lands in the app you started in (hold Fn over a second to talk only while
holding). Shift+Escape cancels.

Three things only you can click:
  1. Handy asks for Microphone and Accessibility: allow both (System Settings > Privacy & Security).
  2. When "Handy Router" asks for the microphone, click Allow (it records alongside Handy for the accurate pass).
  3. System Settings > Keyboard: set "Press 🌐 key to" to "Do Nothing", and turn Dictation off there,
     so the Fn key is Handy's alone.

Your words (names, products, jargon that come out wrong): $vocab
One per line, most important first. Used from the next dictation on.

Logs: ~/Library/Logs/handy-router.log, handy-accurate.log   Update: run this again   Remove: zsh $here/uninstall.sh
E
if [[ $ci == 0 ]]; then
  open -e "$vocab"
  open "x-apple.systempreferences:com.apple.Keyboard-Settings.extension" 2>/dev/null || true
fi
