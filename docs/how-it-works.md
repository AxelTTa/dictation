# How it works

Four pieces around [Handy](https://github.com/cjpais/Handy), which does the listening:

| Piece | Mac | Windows |
|---|---|---|
| Watcher: notes the app you start in, records the same mic for the accurate pass | `mac/main.swift`, `mac/capture.swift` (login agent) | `windows/dictation_helper.py` (starts at login) |
| Accurate pass: Whisper, told your words, works through each dictation while you talk | `common/accurate.py` (login agent) | same file, inside the helper |
| Punctuation: full stops, commas and capitals back into a long line | `common/punctuate.py` (login agent) | same file, inside the helper |
| Paste: Handy's "external script"; puts the text in the start app, keeps it on the clipboard if no text box took it | `mac/main.swift` (Handy Router) | `windows/dictation_paste.py` |

At each dictation:
1. You press the shortcut. Handy opens the mic and logs it.
2. The watcher reads that line, notes the app in front and starts streaming the same mic (mono, 16 kHz) to the accurate pass.
3. Handy's live model (Parakeet Unified, streaming) transcribes as you talk.
4. You press again. Handy hands its text to the paste step.
5. The paste step asks for the accurate pass's text, sending Handy's along, and adds punctuation if it is missing.
6. It brings the start app forward, pastes, and goes back to where you are.

Any piece that is missing, slow or unsure falls back to the step before. The worst case is Handy's own text, pasted where you are.

## Why each choice

**Live model: Parakeet Unified EN 0.6B.** It transcribes while you talk, so after you stop only the last fraction of a second is left. Whisper Large on its own made you wait 2 to 5 s after every dictation. Parakeet is English only.

**Accurate pass: Whisper, with your words.**
- **Why it is there.** The live model drops words, mostly small ones in the first second, and cannot be told your vocabulary.
- **How it runs.** The accurate pass cuts the audio at pauses into 15 to 28 s pieces and transcribes each in the background as you talk. Each piece is given your word list (`vocabulary.txt`, then Handy's custom words) and the last 40 words you said. When you stop, only the last piece is left: about 0.6 s on Apple Silicon.
- **Why Whisper.** It was tested on 12 real dictations, with each model given the vocabulary wherever it can take one. Whisper made the fewest errors against what the other models agree on: 6.7 per 100 words, against 8.1 to 8.6 for Cohere Transcribe, Granite Speech and Qwen3-ASR, and 7.6 for the live text. It also got the most custom words right.
- **Why not the others.** Cohere cannot be told words, and it invented some.
- **Why pieces.** A whole 134 s recording transcribed at once loses words.
- **Which Whisper where.** Large v3 runs on Apple Silicon. Large v3 Turbo runs on Windows and Intel Macs, at about half the size.
- **Safety checks.** Before its text replaces Handy's, the accurate pass checks that:
  - the two mostly agree, with no gap and no made-up ending;
  - any opening words it missed (up to 3) are put back;
  - closing words Handy never heard (up to 6) are dropped;
  - a piece that loops is retried, then given up.
- **When Handy's text goes out instead.** The accurate pass has 2 s to answer. If it is too slow or anything looks off, Handy's text goes out. A Windows PC that cannot transcribe 8 s of audio in 2.5 s (no usable graphics card) turns the accurate pass off at start.

**Your words are matched exactly, never fuzzily.**
- **Handy's own setting.** Handy's fuzzy word fixer at its default 0.18 rewrote ordinary words ("out" to OAuth). The setup sets it to 0.05, so it only joins exact split-ups.
- **The accurate pass, multi-word terms.** It joins a term the model split ("Yellow Force" to YellowForce).
- **The accurate pass, single words.** It re-cases a single word only when it is not ordinary English. On Windows, which has no English word list, it never re-cases single words.

**Punctuation.**
- **Why it is there.** Whisper's punctuation comes and goes. One 436-word dictation came back with 5 full stops; the same audio re-run gave 30.
- **When it runs.** When a text is English and under-punctuated, a small local model (1-800-BAD-CODE/punct_cap_seg_en, 8-bit, about 10 ms) puts full stops, commas, question marks and sentence starts back.
- **What it never does.** It never changes, adds or drops a word.

**Paste into the start app.**
- **The usual case.** If you are still in the same app, it is a plain paste. Otherwise the start app comes forward, the text is pasted, and you go back to where you are, in about half a second. If the start app has quit, or started more than 3 hours ago, the text goes where you are.
- **On a Mac, checking it landed.** The router reads the focused text box afterwards. If the words are there, your old clipboard comes back. If no text box took them, they stay on the clipboard and you hear a soft tick. Apps that do not say what has focus (some Electron apps, canvas editors) keep the words on the clipboard too.
- **On Windows.** The words always stay on the clipboard.
- **Never hangs Handy.** Handy waits for the paste step with no time limit. After 6 s the paste step puts the words on the clipboard and quits.

**Handy settings the setup changes.**
- **Hold limit 1 s.** Handy times the key release only after the recording has started, and the live model takes 0.2 to 0.4 s to start. At Handy's default 0.3 s, a quick tap was often read as a hold, and the recording stopped on release.
- **Cancel is Shift+Escape.** Bare Escape cancelled dictations whenever Escape was pressed for anything else.
- **Minimal overlay.** The recording pill shows, but no words on screen while you talk.
- **Update check off.** The helpers read Handy's log lines, so a Handy update could break them. The setup pins 0.9.8.

## Mac only

- **Handy always running.** The watcher starts Handy whenever it has not been running for 10 s: after a restart of the Mac it did not always come back on its own, and Fn did nothing.
- **A mic that goes silent.** Earbuds can drop out while still plugged in. Handy Mics then gives no sound at all and every dictation comes out empty. The first such dictation plays a low "Funk", puts Handy Mics on the Mac's own mic and restarts Handy; the earbuds come back when a mic is plugged in or out.
- **Fn listener self-repair.** macOS switches off an event tap that stalls (after a night asleep, for example), and Handy never turns it back on, so Fn did nothing. Every 2 s the watcher checks Handy's tap and restarts Handy between dictations if it is off.
- **"Handy Mics".**
  - **What it is.** The watcher keeps one CoreAudio device holding every real microphone: the Mac's own, plus earbuds, USB or Bluetooth mics while they are connected. Handy records from it, so a far earbud mic no longer makes Handy hear "no speech".
  - **Lining up the mics.** USB mics get extra latency, so the mics are lined up within about 2 ms instead of echoing.
  - **Picking the closer mic.** Optionally, the watcher picks the closer mic for each dictation (`HANDY_ROUTER_PICK_MIC=1`, which the setup turns on).
  - **When Handy reads too few channels.** Handy works out how many channels to read once per launch. When the watcher sees Handy reading fewer channels than there are mics, it restarts Handy once you have been idle for 15 s.
- **You hear when nothing came out.** A recording of 1.5 s or more that gives no text plays a low "Funk". So does Handy waiting more than 5 s for macOS to hand it the mic.
- **Microphone permission survives rebuilds.** The router is signed by name, so macOS keeps its microphone permission across rebuilds. It only asks while someone is at the Mac: an unanswered permission prompt once froze the watcher.

## Tests

- **Mac: `zsh mac/build.sh test`.**
  - The watcher: rotation, truncation, channel counts, no-text and cancel lines.
  - Routing, run dry: nothing is pasted and no app is brought forward.
  - The punctuation and accurate-pass helpers.
  - A spoken sentence (macOS `say`) through the accurate pass, with a test word list.
- **Windows: `windows\test.ps1`, after `install.cmd`.**
  - The install itself.
  - A spoken sentence (Windows speech) through the accurate pass.
  - A full dictation through a second helper, with the sentence played in place of the mic. It is started in one Notepad window, ended in another, and must land in the first.
- **On GitHub.** `.github/workflows/test.yml` runs both on fresh machines.
