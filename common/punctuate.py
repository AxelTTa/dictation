"""Handy punctuation helper: puts sentences, commas and capitals back into a transcript Whisper left as one long line.

Whisper's punctuation comes and goes (Nov 7: one 436-word dictation came back with 5 full stops and 1 comma; the same
audio re-run gave 30). When a transcript is English and under-punctuated, this rebuilds it from its own words and takes
only punctuation, sentence starts and capitals from a small local model (1-800-BAD-CODE/punct_cap_seg_en, ONNX, ~50 ms).
It never changes, adds or drops a word; names in Handy's custom words keep their spelling.

    punctuate.py --serve SOCKET    Mac login agent: answers the router on a Unix socket (one transcript in, one out)
    punctuate.py --text '...'      one-off, prints the result
    (Windows: dictation_helper.py runs it in-process.)
"""
import json
import os
import re
import socket
import sys
import time

if sys.platform == "win32":
    HERE = os.environ.get("DICTATION_HOME") or os.path.join(os.environ["LOCALAPPDATA"], "dictation")
    HANDY_SETTINGS = os.path.join(os.environ["APPDATA"], "com.pais.handy", "settings_store.json")
    LOG = os.path.join(HERE, "logs", "punctuate.log")
else:
    HERE = os.environ.get("DICTATION_HOME") or os.path.expanduser("~/Library/Application Support/handy-router")
    HANDY_SETTINGS = os.path.expanduser("~/Library/Application Support/com.pais.handy/settings_store.json")
    LOG = os.path.expanduser("~/Library/Logs/handy-punctuate.log")
sys.path.insert(0, os.path.join(HERE, "py"))  # Mac: onnxruntime, sentencepiece, numpy (build.sh installs them here)

import numpy as np  # noqa: E402
import onnxruntime as ort  # noqa: E402
import sentencepiece as spm  # noqa: E402

MODEL_DIR = os.environ.get("HANDY_PUNCT_MODEL", os.path.join(HERE, "punct-model"))
POST_LABELS = [None, "<ACRONYM>", ".", ",", "?"]  # the model's config.yaml
MAX_TOKENS = 250  # trained on 256 with BOS/EOS
OVERLAP_WORDS = 8

WORD = re.compile(r"[A-Za-z0-9']+")
EDGE = ".,?!;:…\"“”‘’()[]{}"
ENGLISH = set("the and to i you it is that of a in this so like what my me we for on but with be just can do not".split())


def log(line):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%dT%H:%M:%S ") + line + "\n")
    except OSError:
        pass


class Model:
    def __init__(self, directory=MODEL_DIR):
        options = ort.SessionOptions()
        options.intra_op_num_threads = 2
        options.enable_cpu_mem_arena = False  # memory goes back after each transcript instead of staying pooled
        # 8-bit copy of the published model (build.sh makes it): a quarter of the memory, same marks on test texts
        self.session = ort.InferenceSession(os.path.join(directory, "punct_cap_seg_en.int8.onnx"), options,
                                            providers=["CPUExecutionProvider"])
        self.sp = spm.SentencePieceProcessor(model_file=os.path.join(directory, "spe_32k_lc_en.model"))

    def predict(self, words):
        """Per word: (punctuation after it or None, sentence ends after it, first letter is a capital)."""
        pieces = [self.sp.encode(w.lower()) or [self.sp.unk_id()] for w in words]
        result = [None] * len(words)
        start = 0
        while start < len(words):
            end, tokens = start, 0
            while end < len(words) and tokens + len(pieces[end]) <= MAX_TOKENS:
                tokens += len(pieces[end])
                end += 1
            end = max(end, start + 1)
            ids = [self.sp.bos_id()] + [i for p in pieces[start:end] for i in p] + [self.sp.eos_id()]
            _, post, cap, seg = self.session.run(None, {"input_ids": np.array([ids], dtype=np.int64)})
            at = 1
            keep_until = end if end == len(words) else max(start + 1, end - OVERLAP_WORDS)
            for w in range(start, end):
                first, last = at, at + len(pieces[w]) - 1
                at = last + 1
                if w < keep_until:
                    piece = self.sp.id_to_piece(ids[first])
                    result[w] = (POST_LABELS[int(post[0, last])], bool(seg[0, last]),
                                 bool(cap[0, first, 1 if piece.startswith("▁") else 0]))
            start = keep_until
        return result


def under_punctuated(text):
    """English, at least 10 words, and too few full stops, a long run without one, or no comma in a long text."""
    words = WORD.findall(text)
    if len(words) < 10:
        return False
    letters = [c for c in text if c.isalpha()]
    if sum(c.isascii() for c in letters) < 0.97 * len(letters):
        return False
    if sum(w.lower() in ENGLISH for w in words) < 0.15 * len(words):
        return False
    ends, run, longest = 0, 0, 0
    for token in text.split():
        if WORD.search(token):
            run += 1
            longest = max(longest, run)
        if re.search(r"[.?!][\"”’)]*$", token):
            ends += 1
            run = 0
    return ends * 100 < 5 * len(words) or longest >= 35 or (len(words) >= 25 and "," not in text)


def custom_names():
    """Handy's custom words, by lower case, so the model never re-cases YellowForce or GitHub."""
    try:
        with open(HANDY_SETTINGS, encoding="utf-8") as f:
            doc = json.load(f)
        words = doc.get("settings", doc).get("custom_words") or []
    except (OSError, ValueError):
        words = []
    return {part.lower(): part for w in words for part in w.split()}


def rebuild(text, model, names):
    tokens = text.split()
    cores = []
    for t in tokens:
        lead = len(t) - len(t.lstrip(EDGE))
        trail = len(t.rstrip(EDGE))
        cores.append((t[:lead], t[lead:trail], t[trail:]) if trail > lead else None)
    words = [c[1] for c in cores if c]
    if not words:
        return text
    preds = iter(model.predict(words))
    out, sentence_start, whisper_start = [], True, True
    for token, core in zip(tokens, cores):
        if core is None:
            out.append(token)
            continue
        lead, word, trail = core
        mark, ends, cap = next(preds)
        if mark == "<ACRONYM>":
            mark = None
        keep = re.sub(r"[.,?!]", "", trail)  # quotes, colons, brackets stay; stops and commas come from the model
        if ends and mark not in (".", "?"):
            mark = "."
        if word.lower() in names:
            cased = names[word.lower()]
        elif any(c.isupper() for c in word[1:]):
            cased = word  # acronyms and mixed case (OAuth, AI) as Whisper wrote them
        elif word.lower() == "i" or word.lower().startswith("i'"):
            cased = "I" + word[1:]
        elif sentence_start:
            cased = word[:1].upper() + word[1:]
        elif whisper_start and word[:1].isupper() and not cap:
            cased = word[:1].lower() + word[1:]  # Whisper started a sentence here and the model does not
        else:
            cased = word  # inside a sentence Whisper's casing stands (it knows names; the model over-capitalizes)
        out.append(lead + cased + (mark or "") + keep)
        sentence_start = mark in (".", "?")
        whisper_start = bool(re.search(r"[.?!]", trail))
    rebuilt = " ".join(out)
    assert [w.lower() for w in WORD.findall(rebuilt)] == [w.lower() for w in WORD.findall(text)], "words changed"
    return text[: len(text) - len(text.lstrip())] + rebuilt + text[len(text.rstrip()):]


def punctuate(text, model):
    if not under_punctuated(text):
        return text
    try:
        return rebuild(text, model, custom_names())
    except Exception as error:  # never lose a transcript over punctuation
        log(f"kept the transcript as it was: {error!r}")
        return text


def serve(path):
    model = Model()
    model.predict(["warm", "up"])
    if os.path.exists(path):
        os.unlink(path)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    os.chmod(path, 0o600)
    server.listen(4)
    log(f"ready on {path}")
    while True:
        conn, _ = server.accept()
        with conn:
            conn.settimeout(2)
            try:
                chunks = []
                while True:
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    chunks.append(chunk)
                text = b"".join(chunks).decode("utf-8")
                began = time.time()
                result = punctuate(text, model)
                conn.sendall(result.encode("utf-8"))
                if result != text:
                    log(f"punctuated {len(WORD.findall(text))} words in {int((time.time() - began) * 1000)} ms")
            except Exception as error:
                log(f"request failed: {error!r}")


if __name__ == "__main__":
    if sys.argv[1:2] == ["--serve"]:
        serve(sys.argv[2])
    elif sys.argv[1:2] == ["--text"]:
        print(punctuate(sys.argv[2], Model()))
    else:
        print(__doc__)
