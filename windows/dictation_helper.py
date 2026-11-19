"""Dictation helper for Windows. Runs at login with no window, next to Handy.

- Follows Handy's log. When Handy opens the mic it notes the window you were in, and records the same mic.
- Accurate pass (accurate.py): works through what you say in pieces with Whisper, told your words.
- Punctuation (punctuate.py): puts sentences back into a long line with too few full stops.
- Answers the paste program (dictation_paste.py) on 127.0.0.1 with the final text and the window to paste into.

Nothing here can stop a paste: if this helper is not running, or slow, or anything fails, Handy's own text is pasted
where you are. Logs (counts and timings, never your words): %LOCALAPPDATA%\\dictation\\logs.

    dictation-helper            (what the login entry runs)
    python dictation_helper.py --test-audio a.wav    tests: plays a WAV instead of the mic at each start
"""
import ctypes
import json
import os
import queue
import secrets
import socket
import sys
import threading
import time

HOME = os.environ.get("DICTATION_HOME") or os.path.join(os.environ.get("LOCALAPPDATA", os.path.expanduser("~")), "dictation")
os.environ["DICTATION_HOME"] = HOME
HANDY_LOG = os.environ.get("DICTATION_HANDY_LOG") or os.path.join(
    os.environ.get("LOCALAPPDATA", ""), "com.pais.handy", "logs", "handy.log")
HANDY_SETTINGS = os.path.join(os.environ.get("APPDATA", ""), "com.pais.handy", "settings_store.json")
STATE = os.path.join(HOME, "helper.json")
LOG = os.path.join(HOME, "logs", "helper.log")

START = "Microphone stream initialized"          # Handy has the mic: about 70 ms after the key press
STOPS = ("Live preview finalized",               # the live model is done: the mic is closed
         "Pasting via external script",
         "Initiating operation cancellation")    # cancel shortcut or tray
MAX_START_AGE = 3 * 3600                         # a start older than this is ignored: paste where you are
RATE = 16000


def log(line):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        if os.path.exists(LOG) and os.path.getsize(LOG) > 1_000_000:
            os.replace(LOG, LOG + ".old")
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%dT%H:%M:%S ") + line + "\n")
    except OSError:
        pass


# --- Windows bits -------------------------------------------------------------------------------------------------

if sys.platform == "win32":
    import msvcrt
    from ctypes import wintypes
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateFileW.restype = wintypes.HANDLE
    kernel32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
                                     wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    kernel32.CreateMutexW.restype = wintypes.HANDLE
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel32.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    user32.GetForegroundWindow.restype = wintypes.HWND
    user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]


def open_shared(path):
    """Read Handy's log without ever blocking Handy from rotating it (share read, write and delete)."""
    if sys.platform != "win32":
        return open(path, "rb")
    h = kernel32.CreateFileW(path, 0x80000000, 0x7, None, 3, 0x80, None)  # GENERIC_READ, share all, OPEN_EXISTING
    if h is None or h == wintypes.HANDLE(-1).value:
        raise OSError(f"cannot open {path}")
    return os.fdopen(msvcrt.open_osfhandle(h, os.O_RDONLY), "rb")


def process_name(pid):
    if sys.platform != "win32" or not pid:
        return "?"
    h = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return "?"
    try:
        buf = ctypes.create_unicode_buffer(1024)
        size = wintypes.DWORD(len(buf))
        if kernel32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size)):
            return os.path.basename(buf.value)
        return "?"
    finally:
        kernel32.CloseHandle(h)


def foreground():
    """The window you are typing in, and its program's name."""
    if sys.platform != "win32":
        return None
    hwnd = user32.GetForegroundWindow()
    if not hwnd:
        return None
    pid = wintypes.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    return {"hwnd": int(hwnd), "pid": int(pid.value), "name": process_name(pid.value), "at": time.time()}


def single_instance():
    if sys.platform != "win32":
        return True
    import hashlib  # one helper per install folder (tests run a second one beside yours)
    kernel32.CreateMutexW(None, False, "Local\\dictation-helper-" + hashlib.sha1(HOME.lower().encode()).hexdigest()[:12])
    return ctypes.get_last_error() != 183  # ERROR_ALREADY_EXISTS


# --- following Handy's log ----------------------------------------------------------------------------------------

class LogTail(threading.Thread):
    """Like tail -F: new lines only, survives Handy's log rotation and a log that does not exist yet."""

    def __init__(self, path, on_line):
        super().__init__(daemon=True)
        self.path, self.on_line = path, on_line

    def run(self):
        pos, ident, pending = None, None, b""
        while True:
            time.sleep(0.05)
            try:
                st = os.stat(self.path)
            except OSError:
                pos, ident = 0, None  # appears later: read it from the start
                continue
            now = getattr(st, "st_birthtime_ns", None) if sys.platform == "win32" else st.st_ino  # a new file
            if pos is None:
                pos, ident = st.st_size, now  # at launch: only what comes next
                continue
            if now != ident or st.st_size < pos:
                pos, ident, pending = 0, now, b""  # rotated or truncated
            if st.st_size == pos:
                continue
            try:
                with open_shared(self.path) as f:
                    f.seek(pos)
                    data = f.read(st.st_size - pos)
            except OSError:
                continue
            pos += len(data)
            pending += data
            *lines, pending = pending.split(b"\n")
            for line in lines:
                try:
                    self.on_line(line.decode("utf-8", "replace"))
                except Exception as error:  # one bad line must not stop the watching
                    log(f"line handling failed: {error!r}")


# --- the mic ------------------------------------------------------------------------------------------------------

def handy_microphone():
    try:
        with open(HANDY_SETTINGS, encoding="utf-8") as f:
            doc = json.load(f)
        name = doc.get("settings", doc).get("selected_microphone")
        return None if not name or name.lower() == "default" else name
    except (OSError, ValueError):
        return None


class Capture:
    """Records the mic Handy uses while Handy records, 16 kHz mono, into the accurate pass."""

    def __init__(self, accurate, test_audio=None):
        self.accurate = accurate
        self.test_audio = test_audio
        self.stream = None
        self.rec = None
        self.chunks = queue.Queue()
        self.lock = threading.Lock()
        threading.Thread(target=self.feed, daemon=True).start()

    def feed(self):
        while True:
            rec, chunk = self.chunks.get()
            try:
                self.accurate.add(rec, chunk)
            except Exception as error:
                log(f"audio step failed: {error!r}")

    def start(self):
        import accurate
        with self.lock:
            self.stop_locked()
            rec = accurate.Recording()
            self.accurate.latest = rec
            self.rec = rec
            if self.test_audio:
                threading.Thread(target=self.play_file, args=(rec,), daemon=True).start()
                return
            try:
                self.stream = self.open_stream(rec)
            except Exception as error:
                log(f"could not open the mic: {error!r}; Handy's text will be used")

    def open_stream(self, rec):
        import numpy as np
        import sounddevice as sd
        import accurate
        wanted = handy_microphone()
        device = None
        if wanted:
            for i, d in enumerate(sd.query_devices()):
                # MME (the default here) cuts names at 31 characters
                if d["max_input_channels"] > 0 and d["hostapi"] == sd.default.hostapi and wanted.startswith(d["name"][:31]):
                    device = i
                    break

        def callback(indata, frames, at, status):
            mono = indata.mean(axis=1) if indata.shape[1] > 1 else indata[:, 0]
            if rate != RATE:
                mono = accurate.resample(mono, rate)
            self.chunks.put((rec, np.ascontiguousarray(mono, dtype=np.float32).tobytes()))

        try:  # Windows' own mixer converts to 16 kHz for MME
            rate = RATE
            stream = sd.InputStream(device=device, channels=1, samplerate=RATE, dtype="float32", blocksize=800, callback=callback)
        except Exception:
            rate = int(sd.query_devices(device, "input")["default_samplerate"])
            stream = sd.InputStream(device=device, channels=1, samplerate=rate, dtype="float32",
                                    blocksize=rate // 20, callback=callback)
        stream.start()
        return stream

    def play_file(self, rec):
        """Tests: the WAV as the mic would deliver it, 50 ms at a time, in real time."""
        import wave
        import numpy as np
        import accurate
        w = wave.open(self.test_audio)
        pcm = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
        if w.getnchannels() > 1:
            pcm = pcm.reshape(-1, w.getnchannels()).mean(axis=1)
        pcm = accurate.resample(pcm, w.getframerate())
        for i in range(0, len(pcm), 800):
            if self.rec is not rec:
                return
            self.chunks.put((rec, pcm[i:i + 800].tobytes()))
            time.sleep(0.05)

    def stop(self):
        with self.lock:
            self.stop_locked()

    def stop_locked(self):
        if self.stream is not None:
            try:
                self.stream.stop()
                self.stream.close()
            except Exception:
                pass
        self.stream = None
        self.rec = None


# --- the helper ---------------------------------------------------------------------------------------------------

class Helper:
    def __init__(self, test_audio=None):
        self.start_window = None
        self.accurate = None
        self.capture = None
        self.punct = None
        try:
            import punctuate
            self.punct = punctuate.Model()
            self.punct.predict(["warm", "up"])
        except Exception as error:
            log(f"punctuation off: {error!r}")
        try:
            import accurate
            self.accurate = accurate.Helper(accurate.model_path())
            log(f"accurate pass: {os.path.basename(accurate.model_path())} on {self.accurate.model.device.description}, "
                f"8 s of audio in {self.accurate.speed:.1f} s")
            if self.accurate.too_slow and not test_audio:
                log("this PC is too slow for the accurate pass (no usable GPU?): Handy's own text will be used")
                self.accurate = None
        except BaseException as error:  # SystemExit when no model
            log(f"accurate pass off: {error!r}")
            self.accurate = None
        if self.accurate:
            self.capture = Capture(self.accurate, test_audio)

    def on_line(self, line):
        if START in line:
            window = foreground()
            if window and window["name"].lower() in ("handy.exe",):
                window = None  # started in Handy's own window: paste wherever you are at the end
            self.start_window = window
            if self.capture:
                self.capture.start()
            log(f"start in {window['name'] if window else 'nothing'}")
        elif any(marker in line for marker in STOPS):
            if self.capture:
                self.capture.stop()

    def answer(self, handy):
        """The text to paste and where: the accurate pass if it agrees with Handy's, then punctuation."""
        began = time.time()
        text, source = handy, "Handy's text"
        if self.accurate:
            reply = self.accurate.finish(handy)
            if reply.get("used") == "accurate" and reply.get("text", "").strip():
                text, source = reply["text"], f"accurate pass, {reply.get('ms', 0)}ms"
            else:
                source = f"Handy's text: {reply.get('why', '?')}"
            log("accurate " + " ".join(f"{k}={v}" for k, v in reply.items() if k != "text"))
        punctuated = False
        if self.punct:
            import punctuate
            out = punctuate.punctuate(text, self.punct)
            same = [w.lower() for w in punctuate.WORD.findall(out)] == [w.lower() for w in punctuate.WORD.findall(text)]
            if out and same and out != text:
                text, punctuated = out, True
        start, self.start_window = self.start_window, None
        if start and time.time() - start["at"] > MAX_START_AGE:
            start = None
        return {"text": text, "source": source, "punctuated": punctuated, "start": start,
                "ms": int((time.time() - began) * 1000)}

    def serve(self):
        token = secrets.token_hex(16)
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.bind(("127.0.0.1", 0))
        server.listen(8)
        port = server.getsockname()[1]
        os.makedirs(HOME, exist_ok=True)
        tmp = STATE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"port": port, "token": token, "pid": os.getpid()}, f)
        os.replace(tmp, STATE)
        log(f"ready on 127.0.0.1:{port}")
        while True:
            conn, _ = server.accept()
            threading.Thread(target=self.handle, args=(conn, token), daemon=True).start()

    def handle(self, conn, token):
        with conn:
            try:
                conn.settimeout(5)
                data = b""
                while b"\n" not in data:
                    chunk = conn.recv(65536)
                    if not chunk:
                        return
                    data += chunk
                request = json.loads(data.split(b"\n", 1)[0].decode("utf-8"))
                if not secrets.compare_digest(str(request.get("token", "")), token):
                    return
                if request.get("ping"):
                    reply = {"ok": True, "accurate": self.accurate is not None, "punctuation": self.punct is not None}
                else:
                    reply = self.answer(request.get("handy", ""))
                    log(f"answered: {reply['source']}{', punctuated' if reply['punctuated'] else ''}, "
                        f"{len(reply['text'].split())} words, in {reply['ms']}ms")
                conn.sendall(json.dumps(reply).encode("utf-8"))
            except Exception as error:
                log(f"request failed: {error!r}")


def main():
    test_audio = None
    if "--test-audio" in sys.argv:
        test_audio = sys.argv[sys.argv.index("--test-audio") + 1]
    if not single_instance():
        return
    log(f"starting (Handy's log: {HANDY_LOG})")
    helper = Helper(test_audio)
    LogTail(HANDY_LOG, helper.on_line).start()
    helper.serve()


if __name__ == "__main__":
    main()
