"""Accurate pass: Whisper, told your words, works through a dictation while you are still talking.

Handy's live model (Parakeet, streaming) is instant but drops small words in the first second and does not know your
words ("yellow forest" for YellowForce). While Handy records, the same mic's audio streams here; the helper cuts it at
pauses into 15 to 28 s pieces and transcribes each in the background with Whisper Large v3 (Turbo on Windows), given
your vocabulary (vocabulary.txt, most important first, plus Handy's custom words) and the last 40 words you said.
When you stop, only the last piece is left (~0.6 s on a Mac with Apple Silicon). The paste step then asks for the
text, sending Handy's own; the helper checks the two agree and returns its own, or Handy's when anything looks off.
No answer means Handy's text.

Why Whisper with your words (Nov 19, 12 real dictations, each model told the vocabulary where it can be): fewest
errors against what the other models agree on (6.7 per 100 words; Cohere 8.6, Granite 8.2, Qwen3-ASR 8.3, the live
text 7.6) and the most custom words right (YellowForce 7 times where Cohere had 3). Cohere cannot be told words and
invented some ("yellow foods"). The 8-bit Whisper was no better than the 5-bit one. Pieces matter: a whole 134 s
recording at once loses words.

    accurate.py --serve SOCKET       Mac login agent
    accurate.py --file a.wav [handy text]   one-off: runs a WAV through the same path, prints JSON
    (Windows: dictation_helper.py runs it in-process.)

Socket protocol (one connection each):
    "REC\\n" then raw float32 16 kHz mono PCM until the watcher closes it (one recording)
    "GET {json}\\n" with {"handy": text}: ends the latest recording, replies {"text", "used", "why", ...} as JSON
"""
import json
import os
import queue
import re
import socket
import sys
import threading
import time
from difflib import SequenceMatcher

if sys.platform == "win32":
    HERE = os.environ.get("DICTATION_HOME") or os.path.join(os.environ["LOCALAPPDATA"], "dictation")
    HANDY = os.path.join(os.environ["APPDATA"], "com.pais.handy")
    LOG = os.path.join(HERE, "logs", "accurate.log")
else:
    HERE = os.environ.get("DICTATION_HOME") or os.path.expanduser("~/Library/Application Support/handy-router")
    HANDY = os.path.expanduser("~/Library/Application Support/com.pais.handy")
    LOG = os.path.expanduser("~/Library/Logs/handy-accurate.log")
sys.path.insert(0, os.path.join(HERE, "py"))  # Mac: numpy and transcribe-cpp (build.sh installs them here)

import numpy as np  # noqa: E402

# Handy's own Whisper Large v3 if it has it, else the copy the installer downloaded (Turbo: Intel Macs and Windows).
MODELS = [os.path.join(HANDY, "models", "ggml-large-v3-q5_0.bin"), os.path.join(HERE, "models", "whisper-large-v3-Q5_K_M.gguf"),
          os.path.join(HERE, "models", "whisper-large-v3-turbo-Q5_K_M.gguf")]
RATE = 16000
FRAME = 320                 # 20 ms
MIN_PIECE = 15 * 50         # frames: cut at the first pause after 15 s (shorter pieces lost words: less context)
MAX_PIECE = 28 * 50         # frames: models read 30 s at a time; cut at the quietest moment by 28 s
PAUSE = 15                  # frames (300 ms) quieter than speech
QUIET_DB = 8                # a frame within 8 dB of the noise floor is quiet
SPEECH_DB = 12              # a piece whose loudest 20 ms is not 12 dB over the floor has no speech
SETTLE = 0.12               # s: audio still on its way when the router asks
WAIT = float(os.environ.get("HANDY_ACCURATE_WAIT", 1.8))  # s: the paste step gives up at 2 (tests on slow machines: more)
MAX_AGE = 20 * 60           # s: a recording older than this is never served


def log(line):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%dT%H:%M:%S ") + line + "\n")
    except OSError:
        pass


def model_path():
    for p in [os.environ.get("HANDY_ACCURATE_MODEL")] + MODELS:
        if p and os.path.exists(p):
            return p
    raise SystemExit(f"no Whisper model in {MODELS} (the installer downloads one)")


def custom_words():
    try:
        with open(os.path.join(HANDY, "settings_store.json"), encoding="utf-8") as f:
            doc = json.load(f)
        return doc.get("settings", doc).get("custom_words") or []
    except (OSError, ValueError):
        return []


VOCABULARY = os.environ.get("HANDY_ACCURATE_VOCABULARY") or os.path.join(HERE, "vocabulary.txt")


def vocabulary():
    """Your words, most important first: vocabulary.txt (names, products, jargon; not in the shared repo) then Handy's
    custom words. Models that take a vocabulary are biased towards these spellings."""
    terms = []
    try:
        for line in open(VOCABULARY, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#"):
                terms.append(line)
    except OSError:
        pass
    seen = {t.lower() for t in terms}
    return terms + [w for w in custom_words() if w.lower() not in seen]


class Recording:
    def __init__(self):
        self.began = time.time()
        self.pcm = bytearray()       # float32 16 kHz mono
        self.db = []                 # per 20 ms frame
        self.cut = 0                 # frames already handed to Whisper
        self.pieces = 0
        self.texts = {}              # piece index -> text
        self.ended = False
        self.served = False
        self.language = "en"            # Handy's live model is English only too
        self.done = threading.Condition()

    def frames(self):
        return len(self.db)

    def samples(self, f0, f1):
        return np.frombuffer(bytes(self.pcm[f0 * FRAME * 4:f1 * FRAME * 4]), dtype=np.float32)


class Helper:
    def __init__(self, path):
        import transcribe_cpp as tc
        self.tc = tc
        self.model = tc.Model(path)
        # What this model can be told up front: your words, and what you said just before (Cohere: neither).
        self.takes_vocabulary = self.model.supports("vocabulary")
        self.takes_context = self.model.supports("context_prompt")
        self.whisper = self.model.supports("temperature_fallback")
        self.session = self.model.session()
        self.session.run(np.zeros(RATE, dtype=np.float32), language="en")  # warm up the GPU
        # Too slow to finish a short dictation within the paste step's wait (a PC with no usable GPU): say so, and the
        # Windows helper stops recording for it. Handy's own text goes out either way.
        noise = (np.random.default_rng(0).standard_normal(8 * RATE) * 0.003).astype(np.float32)
        began = time.time()
        self.session.run(noise, language="en")
        self.speed = time.time() - began
        self.too_slow = self.speed > 2.5
        self.jobs = queue.Queue()
        self.latest = None
        self.lock = threading.Lock()
        threading.Thread(target=self.work, daemon=True).start()

    # --- audio in, cut at pauses --------------------------------------------------------------------------------

    def add(self, rec, chunk):
        with self.lock:
            if rec.ended:
                return
            rec.pcm.extend(chunk)
            start, end = len(rec.db) * FRAME, (len(rec.pcm) // 4 // FRAME) * FRAME
            if end > start:
                frames = np.frombuffer(bytes(rec.pcm[start * 4:end * 4]), dtype=np.float32).reshape(-1, FRAME)
                rec.db.extend((10 * np.log10((frames * frames).mean(axis=1) + 1e-10)).tolist())
            self.maybe_cut(rec)

    def maybe_cut(self, rec, final=False):
        n = rec.frames()
        if final:
            if n > rec.cut:
                self.hand_over(rec, rec.cut, n)
            return
        if n - rec.cut < MIN_PIECE:
            return
        db = np.array(rec.db)
        floor = np.percentile(db, 10)
        quiet = db < floor + QUIET_DB
        run = 0
        for f in range(rec.cut + MIN_PIECE, n):  # the first pause after 6 s
            run = run + 1 if quiet[f] else 0
            if run >= PAUSE:
                self.hand_over(rec, rec.cut, f - PAUSE // 2)
                return
        if n - rec.cut >= MAX_PIECE:  # no pause: cut at the quietest 20 ms of the last 4 s
            look = db[n - 200:n]
            self.hand_over(rec, rec.cut, n - 200 + int(np.argmin(look)))

    def hand_over(self, rec, f0, f1):
        rec.cut = f1
        db = rec.db[f0:f1]
        floor = np.percentile(np.array(rec.db), 10)
        if not db or max(db) < floor + SPEECH_DB:  # no speech in it: Whisper would make some up
            return
        rec.pieces += 1
        self.jobs.put((rec, rec.pieces - 1, rec.samples(f0, f1)))

    # --- Whisper ----------------------------------------------------------------------------------------------

    def transcribe(self, pcm, before, with_context=True):
        kwargs = {"language": "en"}
        if self.takes_vocabulary:
            kwargs["vocabulary"] = vocabulary()
        if self.takes_context and with_context and before.strip():
            kwargs["prompt"] = " ".join(before.split()[-40:])
        if self.whisper:  # Whisper's own guard against loops: a repetitive or unlikely decode is redone a little warmer
            kwargs["family"] = self.tc.WhisperRunOptions(temperature_inc=0.2, compression_ratio_thold=2.4, logprob_thold=-1.0)
        return self.session.run(pcm, **kwargs).text.strip()

    def work(self):
        while True:
            rec, index, pcm = self.jobs.get()
            text = ""
            try:
                before = " ".join(rec.texts[i] or "" for i in sorted(rec.texts) if i < index)
                text = self.transcribe(pcm, before)
                if looped(text):  # Nov 18: one Whisper piece came back as "from" eleven times; retry without the context
                    text = self.transcribe(pcm, before, with_context=False)
                    if looped(text):
                        log(f"piece {index} kept repeating itself; Handy's text will be used")
                        text = None
            except Exception as error:  # a piece that fails leaves a gap, and the router then falls back to Handy's text
                log(f"piece {index} failed: {error!r}")
                text = None
            with rec.done:
                rec.texts[index] = text
                rec.done.notify_all()

    # --- the router asks ------------------------------------------------------------------------------------------

    def finish(self, handy):
        began = time.time()
        rec = self.latest
        if rec is None or rec.served or began - rec.began > MAX_AGE:
            return {"text": "", "used": "handy", "why": "no recording captured"}
        rec.served = True
        time.sleep(SETTLE)
        with self.lock:
            rec.ended = True
            tail = rec.frames() - rec.cut
            self.maybe_cut(rec, final=True)
        with rec.done:
            rec.done.wait_for(lambda: len(rec.texts) >= rec.pieces, timeout=WAIT - SETTLE)
        waited = time.time() - began
        info = {"seconds": round(rec.frames() / 50, 1), "pieces": rec.pieces, "tail": round(tail / 50, 1), "ms": int(waited * 1000)}
        if len(rec.texts) < rec.pieces or any(rec.texts[i] is None for i in rec.texts):
            return {"text": "", "used": "handy", "why": "accurate pass not done in time", **info}
        found = fix_custom_words(" ".join(rec.texts[i] for i in sorted(rec.texts) if rec.texts[i]))
        text, used, why = choose(found, handy, rec.language)
        return {"text": text, "used": used, "why": why, "language": rec.language, **info}

    # --- socket -------------------------------------------------------------------------------------------------

    def serve(self, path):
        if os.path.exists(path):
            os.unlink(path)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        os.chmod(path, 0o600)
        server.listen(8)
        log(f"ready on {path} ({self.model.device.description}, 8 s of audio in {self.speed:.1f} s)")
        while True:
            conn, _ = server.accept()
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()

    def handle(self, conn):
        with conn:
            try:
                head = b""
                while b"\n" not in head:
                    chunk = conn.recv(65536)
                    if not chunk:
                        return
                    head += chunk
                line, rest = head.split(b"\n", 1)
                if line == b"REC":
                    rec = Recording()
                    self.latest = rec
                    pending = bytearray(rest)
                    while True:
                        usable = len(pending) - len(pending) % 4
                        if usable:
                            self.add(rec, pending[:usable])
                            del pending[:usable]
                        chunk = conn.recv(65536)
                        if not chunk:
                            break
                        pending.extend(chunk)
                elif line.startswith(b"GET"):
                    handy = json.loads(line[3:].decode("utf-8") or "{}").get("handy", "")
                    reply = self.finish(handy)
                    conn.sendall(json.dumps(reply).encode("utf-8"))
                    log("served " + " ".join(f"{k}={v}" for k, v in reply.items() if k != "text") + f" words={len(reply['text'].split())}")
            except Exception as error:
                log(f"connection failed: {error!r}")


# --- choosing between Whisper and Handy ---------------------------------------------------------------------------

ENGLISH = set()  # without a dictionary (Windows), single words are never re-cased, only split terms joined
try:
    ENGLISH = {w.strip().lower() for w in open("/usr/share/dict/words")}
except OSError:
    pass


def fix_custom_words(text):
    """Your words where the model split or re-cased them ("Yellow Force", "post gres"): exact matches only, since a
    fuzzy match turned "out" into OAuth (Nov 10). A single word is re-cased only when it is not ordinary English, so
    "shine" or "handy" in a sentence stay as they are."""
    names = {re.sub(r"[^a-z0-9]", "", w.lower()): w for w in vocabulary()}
    words, out, i = text.split(), [], 0
    while i < len(words):
        for n in (3, 2, 1):
            group = words[i:i + n]
            if len(group) == n and all(not re.search(r"[.,?!;:]$", w) for w in group[:-1]):
                key = re.sub(r"[^a-z0-9]", "", "".join(group).lower())
                plain = group[0].strip(".,?!;:\"'")
                if key in names and (n > 1 or (ENGLISH and plain != names[key] and plain.lower() not in ENGLISH)):
                    tail = re.search(r"[^A-Za-z0-9]*$", group[-1]).group()
                    head = re.match(r"^[^A-Za-z0-9]*", group[0]).group()
                    out.append(head + names[key] + tail)
                    i += n
                    break
        else:
            out.append(words[i])
            i += 1
    return " ".join(out)


def looped(text):
    """Whisper's failure mode: the same word or short phrase over and over."""
    words = [re.sub(r"[^a-z0-9']", "", w.lower()) for w in text.split()]
    for size in (1, 2, 3):
        for i in range(len(words) - 4 * size + 1):
            if words[i:i + size] * 4 == words[i:i + 4 * size]:
                return True
    return False


def tokens(text):
    """Original words with their punctuation, and the bare lower-case word each one compares as."""
    out = [(t, re.sub(r"[^a-z0-9']", "", t.lower())) for t in text.split()]
    return [(t, k) for t, k in out if k and k not in ("uh", "um", "uhm", "umm", "hmm", "mm")]


def choose(found, handy, language):
    """The accurate model's text unless it clearly disagrees with Handy's (a gap, a wrong recording, made-up words)."""
    if not found.strip():
        return handy, "handy", "the accurate model heard nothing"
    if language == "fr":
        return found, "accurate", "French (Handy's live model is English only)"
    h, w = tokens(handy), tokens(found)
    if not h:
        return found, "accurate", "Handy had no words"
    hk, wk = [k for _, k in h], [k for _, k in w]
    sm = SequenceMatcher(a=hk, b=wk, autojunk=False)
    ratio = sm.ratio()
    if len(hk) >= 4 and (ratio < 0.5 or len(wk) < 0.6 * len(hk) or len(wk) > 1.6 * len(hk) + 3):
        return handy, "handy", f"too different from Handy's ({ratio:.2f}, {len(wk)} vs {len(hk)} words)"
    blocks = [b for b in sm.get_matching_blocks() if b.size >= 2]
    words = [t for t, _ in w]
    note = ""
    if blocks:
        first, last = blocks[0], blocks[-1]
        # Whisper's audio starts a moment after Handy's: put back up to 3 words it never heard.
        if first.b == 0 and 1 <= first.a <= 3:
            words = [t for t, _ in h[:first.a]] + words
            note += f", +{first.a} opening word(s) from Handy"
            shift = first.a
        else:
            shift = 0
        # Words after everything Handy heard: a made-up "Thank you." or speech after Fn. Drop up to 6.
        extra = len(wk) - (last.b + last.size)
        if last.a + last.size == len(hk) and 1 <= extra <= 6:
            words = words[:len(words) - extra]
            if words and not re.search(r"[.?!]$", words[-1]):
                words[-1] = words[-1].rstrip(",;:") + "."
            note += f", -{extra} closing word(s) Handy did not hear"
    return " ".join(words), "accurate", f"agrees with Handy's ({ratio:.2f}){note}"


def resample(pcm, rate):
    """Any rate to 16 kHz: a windowed-sinc low-pass at 7 kHz, then linear interpolation."""
    if rate == RATE:
        return pcm.astype(np.float32)
    n = 63
    x = np.arange(n) - (n - 1) / 2
    fc = 7000 / rate
    taps = 2 * fc * np.sinc(2 * fc * x) * np.blackman(n)
    smooth = np.convolve(pcm, taps / taps.sum(), mode="same")
    t = np.arange(0, len(pcm) / rate, 1 / RATE)
    return np.interp(t, np.arange(len(pcm)) / rate, smooth).astype(np.float32)


def run_file(path, handy=""):
    import wave
    w = wave.open(path)
    pcm = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
    if w.getnchannels() > 1:
        pcm = pcm.reshape(-1, w.getnchannels()).mean(axis=1)
    if w.getframerate() != RATE:
        pcm = resample(pcm, w.getframerate())
    helper = Helper(model_path())
    rec = Recording()
    helper.latest = rec
    step = RATE // 10
    for i in range(0, len(pcm), step):  # as the watcher sends it, 100 ms at a time (here faster than real time)
        helper.add(rec, pcm[i:i + step].tobytes())
    while not helper.jobs.empty():
        time.sleep(0.01)
    with rec.done:
        rec.done.wait_for(lambda: len(rec.texts) >= rec.pieces, timeout=60)
    print(json.dumps(helper.finish(handy)))


if __name__ == "__main__":
    if sys.argv[1:2] == ["--serve"]:
        Helper(model_path()).serve(sys.argv[2])
    elif sys.argv[1:2] == ["--file"]:
        run_file(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "")
    else:
        print(__doc__)
