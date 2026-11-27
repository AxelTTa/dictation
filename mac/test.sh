#!/bin/zsh
# zsh test.sh <HandyRouter binary>: checks the log watcher (append, rotation, truncation) and the routing
# decision on temp files. Dry run only: nothing is pasted and no app is brought forward.
bin="${1:A}"
tmp=$(mktemp -d)
export HANDY_ROUTER_HANDY_LOG="$tmp/handy.log" HANDY_ROUTER_STATE="$tmp/start.json" HANDY_ROUTER_LOG="$tmp/router.log"
export HANDY_ROUTER_ACCURATE="$tmp/no-accurate.sock"  # never the real accurate pass (it would hand over a real recording)
export HANDY_ROUTER_DRY=1  # nothing in a test may ever paste (Nov 18: a mistyped mode pasted an "x" into the front app)
marker="[2026-11-02][10:00:00][handy_app_lib::managers::audio][INFO] Microphone stream initialized in 70ms"
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi }
waitfor() { for _ in {1..30}; do [[ -f "$HANDY_ROUTER_STATE" ]] && return; sleep 0.1; done }

echo "$marker" > "$HANDY_ROUTER_HANDY_LOG"
HANDY_ROUTER_MODE=watch HANDY_ROUTER_DRY=1 HANDY_ROUTER_HANDY_PID=999999 "$bin" & watcher=$!
sleep 1.5  # a freshly built binary takes a moment to start the first time
check "old lines are ignored" '[[ ! -f $HANDY_ROUTER_STATE ]]'

echo "[INFO] unrelated line" >> "$HANDY_ROUTER_HANDY_LOG"
sleep 0.3
check "other lines are ignored" '[[ ! -f $HANDY_ROUTER_STATE ]]'

echo "$marker" >> "$HANDY_ROUTER_HANDY_LOG"; waitfor
check "a new start is noted" '[[ -f $HANDY_ROUTER_STATE ]]'
check "it names the front app" 'grep -q "\"pid\"" $HANDY_ROUTER_STATE'
rm -f "$HANDY_ROUTER_STATE"

mv "$HANDY_ROUTER_HANDY_LOG" "$tmp/handy.old"
echo "$marker" > "$HANDY_ROUTER_HANDY_LOG"; waitfor
check "survives rotation" '[[ -f $HANDY_ROUTER_STATE ]]'
rm -f "$HANDY_ROUTER_STATE"

: > "$HANDY_ROUTER_HANDY_LOG"; sleep 1.2
echo "$marker" >> "$HANDY_ROUTER_HANDY_LOG"; waitfor
check "survives truncation" '[[ -f $HANDY_ROUTER_STATE ]]'
kill $watcher 2>/dev/null

# A stand-in Handy (pid 999999) that never records: each start ends at once, with or without text.
: > "$HANDY_ROUTER_LOG"
# An earlier Handy's channel count, then a relaunch: the new Handy has not settled on one yet.
printf '%s\n' '[2026-11-09][09:00:00][handy_app_lib::audio_toolkit::audio::recorder][INFO] Using device: Ok("Handy Mics")' \
  'Sample rate: 48000' 'Channels: 1' 'Format: F32' \
  '[2026-11-09][09:30:00][handy_app_lib::managers::transcription][INFO] transcribe-cpp initialized with 2 compute device(s)' >> "$HANDY_ROUTER_HANDY_LOG"
HANDY_ROUTER_MODE=watch HANDY_ROUTER_DRY=1 HANDY_ROUTER_HANDY_PID=999999 HANDY_ROUTER_QUIET_GRACE=1 HANDY_ROUTER_OPENING_LIMIT=1 "$bin" & watcher=$!
sleep 1.5  # a freshly built binary takes a moment to start the first time
check "an earlier Handy's channel count is not taken for the running one's" '! grep -q "Handy reads" $HANDY_ROUTER_LOG'
printf '%s\n' '[2026-11-09][10:00:00][handy_app_lib::audio_toolkit::audio::recorder][INFO] Using device: Ok("Handy Mics")' \
  'Sample rate: 48000' 'Channels: 2' 'Format: F32' "$marker" >> "$HANDY_ROUTER_HANDY_LOG"
sleep 2.5
check "reads how many mic channels Handy opened" 'grep -q "Handy reads 2 channel" $HANDY_ROUTER_LOG'
check "says when a recording gave no text" 'grep -q "no text came out" $HANDY_ROUTER_LOG'
check "a recording whose mic gave no sound at all is caught (earbuds that dropped out)" 'grep -q "mic gave no sound" $HANDY_ROUTER_LOG'
quiet=$(grep -c "no text came out" "$HANDY_ROUTER_LOG")
echo "$marker" >> "$HANDY_ROUTER_HANDY_LOG"; sleep 0.3
echo "[2026-11-09][10:00:05][handy_app_lib::clipboard][INFO] Pasting via external script: x" >> "$HANDY_ROUTER_HANDY_LOG"
sleep 2.5
check "a recording that gave text is not reported" '[[ $(grep -c "no text came out" $HANDY_ROUTER_LOG) == $quiet ]]'
check "says how long the text took after the mic closed" 'grep -q "text came .*s after the mic closed" $HANDY_ROUTER_LOG'
echo "$marker" >> "$HANDY_ROUTER_HANDY_LOG"; sleep 0.3
echo "[2026-11-09][10:00:09][handy_app_lib::utils][INFO] Initiating operation cancellation..." >> "$HANDY_ROUTER_HANDY_LOG"
sleep 2.5
echo '[2026-11-09][10:00:20][handy_app_lib::audio_toolkit::audio::recorder][INFO] Using device: Ok("Handy Mics")' >> "$HANDY_ROUTER_HANDY_LOG"
sleep 2.5
check "says when macOS does not hand Handy the mic" 'grep -q "waited 1s for macOS to open the mic" $HANDY_ROUTER_LOG'
check "a cancelled recording says cancelled, not no speech" 'grep -q "recording cancelled" $HANDY_ROUTER_LOG && [[ $(grep -c "no text came out" $HANDY_ROUTER_LOG) == $quiet ]]'
kill $watcher 2>/dev/null

finder=$(pgrep -x Finder | head -1)
now=$(python3 -c 'import time; print(time.time())')
echo "{\"pid\":$finder,\"bundle\":\"com.apple.finder\",\"name\":\"Finder\",\"at\":$now}" > "$HANDY_ROUTER_STATE"
out=$(HANDY_ROUTER_DRY=1 "$bin" hello world)
check "routes to the start app ($out)" '[[ $out == "route Finder ($finder)"* || $out == "here Finder"* ]]'
check "forgets the start after use" '[[ ! -f $HANDY_ROUTER_STATE ]]'

out=$(HANDY_ROUTER_DRY=1 "$bin" hello)
check "no start: pastes where you are ($out)" '[[ $out == here* ]]'

echo "{\"pid\":$finder,\"bundle\":\"com.apple.finder\",\"name\":\"Finder\",\"at\":1}" > "$HANDY_ROUTER_STATE"
out=$(HANDY_ROUTER_DRY=1 "$bin" hello)
check "a stale start is ignored ($out)" '[[ $out == here* ]]'

echo "{\"pid\":999999,\"bundle\":\"x\",\"name\":\"gone\",\"at\":$now}" > "$HANDY_ROUTER_STATE"
out=$(HANDY_ROUTER_DRY=1 "$bin" hello)
check "a quit start app is ignored ($out)" '[[ $out == here* ]]'

HANDY_ROUTER_MODE=watch HANDY_ROUTER_DRY=1 HANDY_ROUTER_PUNCTUATE=/nonexistent.sock "$bin" hello > "$tmp/inherited.out" & p=$!
for _ in {1..30}; do kill -0 $p 2>/dev/null || break; sleep 0.1; done
kill $p 2>/dev/null && hung=1 || hung=0
check "a paste with Handy carrying the watch setting still pastes ($(cat "$tmp/inherited.out"))" '[[ $hung == 0 && $(cat "$tmp/inherited.out") == here* ]]'

if [[ -S "$HOME/Library/Application Support/handy-router/punctuate.sock" ]]; then
  out=$(HANDY_ROUTER_MODE=punctuate "$bin" "so i tried it twice and it still did not work then i restarted the mac and now it works fine with Claude")
  check "punctuation goes into a long line ($out)" '[[ $out == So* && $out == *.* && $out == *Claude* ]]'
  out=$(HANDY_ROUTER_MODE=punctuate "$bin" "This is fine. It already has sentences, and commas too.")
  check "punctuated text is left alone" '[[ $out == "This is fine. It already has sentences, and commas too." ]]'
  out=$(HANDY_ROUTER_PUNCTUATE=/nonexistent.sock HANDY_ROUTER_MODE=punctuate "$bin" "no helper so the text goes out as it came in from handy without any change")
  check "no helper: text unchanged" '[[ $out == "no helper so the text goes out as it came in from handy without any change" ]]'
else
  echo "skip punctuation checks (helper not installed)"
fi

# Accurate pass, router side: a stand-in helper answering like accurate.py.
fake() {  # fake <socket> <reply json> [delay s]
  /usr/bin/python3 -c '
import socket, sys, os, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1)
c, _ = s.accept(); c.recv(65536); time.sleep(float(sys.argv[3])); c.sendall(sys.argv[2].encode()); c.close()
' "$1" "$2" "${3:-0}" & sleep 0.3; }
out=$(HANDY_ROUTER_MODE=accurate "$bin" "handy words")
check "no accurate pass: Handy's text ($out)" '[[ $out == "handy words" ]]'
fake "$tmp/a1.sock" '{"text": "Accurate words.", "used": "accurate", "why": "agrees", "ms": 210}'
out=$(HANDY_ROUTER_ACCURATE="$tmp/a1.sock" HANDY_ROUTER_MODE=accurate "$bin" "handy words")
check "accurate pass answers: its text ($out)" '[[ $out == "Accurate words. (accurate pass, 210ms)" ]]'
fake "$tmp/a2.sock" '{"text": "handy words", "used": "handy", "why": "too different"}'
out=$(HANDY_ROUTER_ACCURATE="$tmp/a2.sock" HANDY_ROUTER_MODE=accurate "$bin" "handy words")
check "accurate pass says use Handy's: Handy's text ($out)" '[[ $out == "handy words (Handy'"'"'s text: too different)" ]]'
fake "$tmp/a3.sock" '{"text": "late", "used": "accurate"}' 3
t0=$(/usr/bin/python3 -c 'import time; print(time.time())')
out=$(HANDY_ROUTER_ACCURATE="$tmp/a3.sock" HANDY_ROUTER_MODE=accurate "$bin" "handy words")
waited=$(/usr/bin/python3 -c "import time; print(round(time.time() - $t0, 1))")
check "accurate pass too slow: Handy's text within 2.5 s ($out, ${waited}s)" '[[ $out == "handy words"* && $waited -lt 2.5 ]]'

# Accurate pass, helper side (needs the installed libraries; the end-to-end check also needs the model).
support="$HOME/Library/Application Support/handy-router"
common="${0:A:h}/../common"
# The words a test speaker uses, whatever the installed list holds.
printf 'YellowForce\nPriya\nPostgres\nOAuth\n' > "$tmp/vocabulary.txt"
export HANDY_ACCURATE_VOCABULARY="$tmp/vocabulary.txt"
if [[ -d "$support/py/transcribe_cpp" ]]; then
  out=$(/usr/bin/python3 - "${common:A}" <<'PY'
import sys, json; sys.path.insert(0, sys.argv[1]); import accurate as a
a.custom_words = lambda: []
print(json.dumps([
  a.choose("Okay, the system seems to be inaccurate.", "Okay, system seems to be inaccurate", "en")[0],
  a.choose("totally different words about the weather today", "make sure you update the folder for all agents", "en")[1],
  a.choose("system seems to be fine today.", "Okay so system seems to be fine today", "en")[0],
  a.choose("make sure it works today. Thank you.", "make sure it works today", "en")[0],
  a.fix_custom_words("use the Yellow Force CRM and post gres, figure out the rest"),
  a.looped("from from from from here"), a.looped("I said no, no, no to that"),
  a.drop_made_up("Send it to Priya today. Thank you for watching!", "send it to priya today"),
  a.drop_made_up("First part done. Thanks for watching. Second part starts now", "first part done second part starts now"),
  a.drop_made_up("I told them thank you for watching the kids.", "i told them thank you for watching the kids"),
]))
PY
)
  check "accurate pass keeps its own better words ($out)" '[[ $out == *"\"Okay, the system seems to be inaccurate.\""* ]]'
  check "accurate pass gives way when it disagrees" '[[ $out == *"\"handy\""* ]]'
  check "accurate pass puts back opening words it missed" '[[ $out == *"\"Okay so system seems to be fine today.\""* ]]'
  check "accurate pass drops a made-up closing phrase" '[[ $out == *"\"make sure it works today.\""* ]]'
  check "custom words joined exactly, never fuzzily" '[[ $out == *"use the YellowForce CRM and Postgres, figure out the rest"* ]]'
  check "a looping piece is caught, a short repeat is not" '[[ $out == *"true, false, ["* ]]'
  check "\"Thank you for watching\" Handy never heard is dropped, at the end or mid-text" '[[ $out == *"[\"Send it to Priya today.\", 1]"* && $out == *"[\"First part done. Second part starts now\", 1]"* ]]'
  check "the same words are kept when you said them" '[[ $out == *"[\"I told them thank you for watching the kids.\", 0]"* ]]'
  if [[ -f "$HOME/Library/Application Support/com.pais.handy/models/ggml-large-v3-q5_0.bin" || -n $(ls "$support"/models/whisper-large-v3*.gguf 2>/dev/null) ]]; then
    say -o "$tmp/say.aiff" "Ask Priya to update the YellowForce dashboard before Friday afternoon, and check every number twice." && \
      afconvert -f WAVE -d LEI16@16000 -c 1 "$tmp/say.aiff" "$tmp/say.wav"
    out=$(/usr/bin/python3 -I "$common/accurate.py" --file "$tmp/say.wav" "Ask Maria to update the yellow folder dashboard before Friday afternoon and check every number twice" 2>/dev/null)
    # The watcher's own 48 to 16 kHz step on the same sentence (as the mic delivers it).
    afconvert -f WAVE -d LEI16@48000 -c 1 "$tmp/say.aiff" "$tmp/say48.wav"
    /usr/bin/python3 -c 'import wave,sys; w=wave.open(sys.argv[1]); import array; a=array.array("h", w.readframes(w.getnframes())); sys.stdout.buffer.write(array.array("f", [x/32768 for x in a]).tobytes())' "$tmp/say48.wav" \
      | HANDY_ROUTER_MODE=decimate "$bin" x \
      | /usr/bin/python3 -c 'import wave,sys,array; f=array.array("f"); f.frombytes(sys.stdin.buffer.read()); w=wave.open(sys.argv[1],"wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(array.array("h",[max(-32768,min(32767,int(x*32767))) for x in f]).tobytes())' "$tmp/say16.wav"
    out2=$(/usr/bin/python3 -I "$common/accurate.py" --file "$tmp/say16.wav" "Ask Maria to update the yellow folder dashboard before Friday afternoon and check every number twice" 2>/dev/null)
    check "the watcher's 48 to 16 kHz audio is heard just as well ($out2)" '[[ $out2 == *"\"used\": \"accurate\""* && $out2 == *"YellowForce dashboard before Friday afternoon"* ]]'
    check "accurate pass end to end on spoken audio, your words spelled right ($out)" '[[ $out == *"\"used\": \"accurate\""* && $out == *"YellowForce dashboard before Friday afternoon"* ]]'
  fi
else
  echo "skip accurate pass helper checks (not installed)"
fi
rm -rf "$tmp"
[[ $fails == 0 ]] && echo "all passed" || { echo "$fails failed"; exit 1; }
