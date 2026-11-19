#!/bin/zsh
# ./build.sh          build build.noindex/Handy Router.app (.noindex keeps it out of Spotlight)
# ./build.sh test     build, then test the log watcher and the routing decision (moves no focus, pastes nothing)
# ./build.sh install  build, copy to ~/Applications, start the watcher, the punctuation helper and the accurate pass at
#                     login, point Handy at them (setup.sh runs this after installing Handy and its model)
set -e
cd "${0:A:h}"
mkdir -p build.noindex
# The name macOS keeps the microphone permission under, and the login agents' names. An install that already exists
# keeps its own (the first Mac this ran on used local.axel), so updating never asks for permissions again.
prefix=local.dictation
[[ -f "$HOME/Library/LaunchAgents/local.axel.handy-router.plist" ]] && prefix=local.axel

app="build.noindex/Handy Router.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
swiftc -O main.swift mics.swift capture.swift -o "$app/Contents/MacOS/HandyRouter"
cat > "$app/Contents/Info.plist" <<E
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>HandyRouter</string>
<key>CFBundleIdentifier</key><string>$prefix.handy-router</string>
<key>CFBundleName</key><string>Handy Router</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Handy Router compares your mics while Handy records and mutes the farther one. It reads levels only and stores no audio.</string>
</dict></plist>
E
# A designated requirement by name, not by build hash: otherwise every rebuild is a new app to macOS, the microphone
# permission is asked again, and nobody may be there to click Allow (Nov 9: that prompt froze the watcher).
codesign -s - --force -r="designated => identifier \"$prefix.handy-router\"" "$app" >/dev/null 2>&1
echo "built $app"

if [[ "$1" == test ]]; then
  exec zsh test.sh "$app/Contents/MacOS/HandyRouter"
fi
[[ "$1" == install ]] || exit 0

dest="$HOME/Applications/Handy Router.app"
bin="$dest/Contents/MacOS/HandyRouter"
label=$prefix.handy-router
plist="$HOME/Library/LaunchAgents/$label.plist"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
sleep 0.5
rm -rf "$dest"
ditto "$app" "$dest"
cat > "$plist" <<E
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>Program</key><string>$bin</string>
<key>EnvironmentVariables</key><dict><key>HANDY_ROUTER_MODE</key><string>watch</string><key>HANDY_ROUTER_PICK_MIC</key><string>1</string></dict>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Interactive</string>
<key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
E
launchctl bootstrap "gui/$(id -u)" "$plist"
sleep 1
pgrep -f "$bin" >/dev/null && echo "watcher running" || { echo "WATCHER NOT RUNNING"; exit 1; }

# Handy keeps its settings in memory, so the router quits it, edits them and reopens it (only if something changes).
cp -n "$HOME/Library/Application Support/com.pais.handy/settings_store.json"{,.bak-before-router} 2>/dev/null || true
HANDY_ROUTER_MODE=configure "$bin"

# Punctuation helper (punctuate.py): three Python libraries, the published model plus an 8-bit copy (a quarter of the
# memory), and its own login agent. The router asks it before every paste and pastes Handy's text if it is not there.
support="$HOME/Library/Application Support/handy-router"
model="$support/punct-model"
mkdir -p "$model"
# /usr/bin/python3 (the command line tools' Python) is what the login agents run, so the libraries are built for it.
[[ -d "$support/py/onnxruntime" ]] || /usr/bin/python3 -m pip install --quiet --disable-pip-version-check --target "$support/py" onnxruntime sentencepiece numpy
for f in punct_cap_seg_en.onnx spe_32k_lc_en.model config.yaml; do
  [[ -f "$model/$f" ]] || curl -sSLf -o "$model/$f" "https://huggingface.co/1-800-BAD-CODE/punct_cap_seg_en/resolve/main/$f"
done
if [[ ! -f "$model/punct_cap_seg_en.int8.onnx" ]]; then
  tools=$(mktemp -d)
  /usr/bin/python3 -m pip install --quiet --disable-pip-version-check --target "$tools" onnx
  PYTHONPATH="$tools:$support/py" /usr/bin/python3 -c "from onnxruntime.quantization import quantize_dynamic, QuantType; import sys; quantize_dynamic(sys.argv[1] + '/punct_cap_seg_en.onnx', sys.argv[1] + '/punct_cap_seg_en.int8.onnx', weight_type=QuantType.QInt8)" "$model"
  rm -rf "${tools:?}"
fi
cp ../common/punctuate.py "$support/punctuate.py"
plabel=$prefix.handy-punctuate
pplist="$HOME/Library/LaunchAgents/$plabel.plist"
launchctl bootout "gui/$(id -u)/$plabel" 2>/dev/null || true
for _ in {1..50}; do launchctl print "gui/$(id -u)/$plabel" >/dev/null 2>&1 || break; sleep 0.1; done  # bootstrap fails while the old one is going
rm -f "$support/punctuate.sock"
cat > "$pplist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Label</key><string>$plabel</string>
<key>ProgramArguments</key><array><string>/usr/bin/python3</string><string>-I</string><string>$support/punctuate.py</string><string>--serve</string><string>$support/punctuate.sock</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
P
launchctl bootstrap "gui/$(id -u)" "$pplist"
for _ in {1..50}; do [[ -S "$support/punctuate.sock" ]] && break; sleep 0.2; done
[[ -S "$support/punctuate.sock" ]] && echo "punctuation helper running" || { echo "PUNCTUATION HELPER NOT RUNNING (see ~/Library/Logs/handy-punctuate.log)"; exit 1; }

# Accurate pass (accurate.py): Whisper Large v3, told your words (vocabulary.txt + Handy's custom words), works
# through each dictation in pieces while you talk, so the router can paste its text ~0.6 s after Fn. transcribe-cpp
# (Metal) beside the punctuation libraries; Handy's own Whisper Large if it has it, else a checked download (1.2 GB;
# Large v3 Turbo, 0.6 GB, on Intel Macs or with DICTATION_WHISPER=turbo).
[[ -d "$support/py/transcribe_cpp" ]] || /usr/bin/python3 -m pip install --quiet --disable-pip-version-check --no-deps --target "$support/py" "transcribe-cpp==0.4.2" "transcribe-cpp-native==0.4.2"
mkdir -p "$support/models"
if [[ "$(uname -m)" == arm64 && "$DICTATION_WHISPER" != turbo ]]; then
  whisper="$support/models/whisper-large-v3-Q5_K_M.gguf"
  url=https://huggingface.co/handy-computer/whisper-large-v3-gguf/resolve/e3e29bee6389c7da4a141406f07bb80ddac5337c/whisper-large-v3-Q5_K_M.gguf
  sum=6053d0fd69a0fd48b8fea5ea7a52b9e0cde389343566fa30e453a1b2b258dc38
  [[ -f "$HOME/Library/Application Support/com.pais.handy/models/ggml-large-v3-q5_0.bin" ]] && whisper=""  # Handy's own
else
  whisper="$support/models/whisper-large-v3-turbo-Q5_K_M.gguf"
  url=https://huggingface.co/handy-computer/whisper-large-v3-turbo-gguf/resolve/5eaf945c7978e564bae5b28a5b1639dd93c2bfb1/whisper-large-v3-turbo-Q5_K_M.gguf
  sum=977b5db4e004349dffd1ab9caa10ba5aaba3fc3edd3ba72cadb84328a3203e36
fi
if [[ -n "$whisper" && ! -f "$whisper" ]]; then
  echo "downloading $(basename "$whisper")"
  curl -sSLf -o "$whisper.part" "$url"
  [[ $(shasum -a 256 "$whisper.part" | cut -d' ' -f1) == "$sum" ]] || { echo "WHISPER MODEL HASH MISMATCH"; rm -f "$whisper.part"; exit 1; }
  mv "$whisper.part" "$whisper"
fi
[[ -f "$support/vocabulary.txt" ]] || cp ../common/vocabulary.example.txt "$support/vocabulary.txt"
cp ../common/accurate.py "$support/accurate.py"
alabel=$prefix.handy-accurate
aplist="$HOME/Library/LaunchAgents/$alabel.plist"
launchctl bootout "gui/$(id -u)/$alabel" 2>/dev/null || true
for _ in {1..50}; do launchctl print "gui/$(id -u)/$alabel" >/dev/null 2>&1 || break; sleep 0.1; done
rm -f "$support/accurate.sock"
cat > "$aplist" <<A
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>Label</key><string>$alabel</string>
<key>ProgramArguments</key><array><string>/usr/bin/python3</string><string>-I</string><string>$support/accurate.py</string><string>--serve</string><string>$support/accurate.sock</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Interactive</string>
<key>LimitLoadToSessionType</key><string>Aqua</string>
<key>StandardErrorPath</key><string>$HOME/Library/Logs/handy-accurate.err</string>
</dict></plist>
A
launchctl bootstrap "gui/$(id -u)" "$aplist"
for _ in {1..150}; do [[ -S "$support/accurate.sock" ]] && break; sleep 0.2; done
[[ -S "$support/accurate.sock" ]] && echo "accurate pass running" || { echo "ACCURATE PASS NOT RUNNING (see ~/Library/Logs/handy-accurate.log and .err)"; exit 1; }
