// Handy Router: Handy's text lands in the app where you started dictating, not the one you ended up in.
//
// HANDY_ROUTER_MODE=watch (login agent): tails Handy's log and notes the front app each time Handy opens the mic.
// HandyRouter <text> (Handy's external paste script): brings that app forward, pastes, and goes back to the
// app you are in now. Runs as Handy's child, so macOS counts its keystrokes as Handy's (Accessibility already granted).
// If the words do not show up in a text box, they stay on the clipboard (with a tick when no text box had focus).
// The watcher also keeps "Handy Mics" (every microphone in one device, mics.swift) for Handy to record from.
import AppKit
import ApplicationServices

let env = ProcessInfo.processInfo.environment
let home = FileManager.default.homeDirectoryForCurrentUser.path
let handyLogPath = env["HANDY_ROUTER_HANDY_LOG"] ?? "\(home)/Library/Logs/com.pais.handy/handy.log"
let statePath = env["HANDY_ROUTER_STATE"] ?? "\(home)/Library/Application Support/handy-router/start.json"
let logPath = env["HANDY_ROUTER_LOG"] ?? "\(home)/Library/Logs/handy-router.log"
let dryRun = env["HANDY_ROUTER_DRY"] == "1"
/// Handy logs this once per recording, about 70ms after the key press.
let startMarker = "Microphone stream initialized"
let handyBundle = "com.pais.handy"
/// A start older than this is ignored and the text goes where you are now.
let maxRecordingAge: TimeInterval = 3 * 3600

/// The watcher logs from its main thread and its audio queues.
let logLock = NSLock()

func log(_ line: String) {
    logLock.lock()
    defer { logLock.unlock() }
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withFullTime])
    let data = Data("\(stamp) \(line)\n".utf8)
    if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
       (attrs[.size] as? Int ?? 0) > 1_000_000 {
        try? FileManager.default.removeItem(atPath: logPath)
    }
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: data)
    }
}

func label(_ app: NSRunningApplication?) -> String {
    guard let app else { return "nothing" }
    return "\(app.localizedName ?? app.bundleIdentifier ?? "?") (\(app.processIdentifier))"
}

struct Start: Codable {
    let pid: Int32
    let bundle: String?
    let name: String?
    let at: Double
}

// MARK: - watch

/// Follows Handy's log like `tail -F`: survives Handy's rotation at 500 KB.
final class LogTail {
    let path: String
    let onLine: (String) -> Void
    private var fd: Int32 = -1
    private var opened = false
    private var inode: UInt64 = 0
    private var source: DispatchSourceFileSystemObject?
    private var pending = Data()

    init(path: String, onLine: @escaping (String) -> Void) {
        self.path = path
        self.onLine = onLine
    }

    func start() {
        reopen(atEnd: true)
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
    }

    private func reopen(atEnd: Bool) {
        source?.cancel()
        source = nil
        fd = -1
        pending.removeAll()
        let f = open(path, O_RDONLY)
        guard f >= 0 else { return }
        opened = true
        var st = stat()
        fstat(f, &st)
        inode = UInt64(st.st_ino)
        lseek(f, atEnd ? st.st_size : 0, SEEK_SET)
        fd = f
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: f, eventMask: [.extend, .write, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.readNew()
            if !src.data.intersection([.delete, .rename]).isEmpty { self.reopen(atEnd: false) }
        }
        src.setCancelHandler { close(f) }
        source = src
        src.resume()
        if !atEnd { readNew() }
    }

    /// Catches a rotation the file events missed, a truncation, or a log that did not exist yet.
    private func check() {
        var st = stat()
        guard stat(path, &st) == 0 else { return }
        guard source != nil else { reopen(atEnd: !opened); return }
        if UInt64(st.st_ino) != inode || st.st_size < lseek(fd, 0, SEEK_CUR) {
            reopen(atEnd: false)
        } else {
            readNew()
        }
    }

    private func readNew() {
        guard source != nil else { return }
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            pending.append(buf, count: n)
        }
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...nl)
            onLine(line)
        }
    }
}

func noteStart() {
    guard let app = NSWorkspace.shared.frontmostApplication else { return }
    if app.bundleIdentifier == handyBundle {
        try? FileManager.default.removeItem(atPath: statePath)
        log("start in Handy itself: text goes wherever you are at the end")
        return
    }
    let start = Start(pid: app.processIdentifier, bundle: app.bundleIdentifier, name: app.localizedName,
                      at: Date().timeIntervalSince1970)
    let dir = (statePath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(start) {
        try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }
    log("start in \(label(app))")
}

/// Handy logs this when it hands the text to the router.
let pasteMarker = "Pasting via external script"
/// Shift+Escape, the tray's Cancel, or `handy --cancel`.
let cancelMarker = "Initiating operation cancellation"
/// Handy logs this once per launch; its log carries on across launches.
let launchMarker = "transcribe-cpp initialized with"
/// Test hook: seconds Handy may take to get the mic before the watcher says it is stuck (normally 5).
let openingLimit = env["HANDY_ROUTER_OPENING_LIMIT"].flatMap(Double.init) ?? 5
/// Test hook: seconds to wait for text after the mic closes (normally 15 s plus a tenth of the recording).
let quietGrace = env["HANDY_ROUTER_QUIET_GRACE"].flatMap(Double.init)

/// Follows each recording from Handy's log and its mic: knows when Handy is busy (recording, transcribing, pasting), and
/// says so when a recording ends with no text, which Handy does silently when it heard no speech (cancels it logs).
final class Recordings {
    private var began: Date?
    private var stopped: Date?
    /// Whether macOS ever showed Handy recording during this recording. Never: its mic gave no sound at all.
    private var heard = false
    private var finished = Date.distantPast
    private var timer: Timer?
    /// Called once when Handy's mic closes (the accurate-pass capture stops there).
    var micClosed: () -> Void = {}
    /// Called when a recording ended with no text and Handy's mic never ran: a mic in Handy Mics stopped giving sound.
    var micDead: () -> Void = {}
    /// The router can take up to 6 s after Handy hands it the text.
    var busy: Bool { began != nil || Date().timeIntervalSince(finished) < 7 }

    func started() {
        // Fn pressed again before the previous recording's grace ran out: say what happened to that one too
        // (Nov 14: three taps in a row each recorded ~1 s, read by Handy as holds, and only the last was logged).
        if let previous = began, let closed = stopped {
            log("no text came out of a \(Int(closed.timeIntervalSince(previous).rounded()))s recording (Handy heard no speech)")
            if !heard { micDead() }
        }
        began = Date()
        stopped = nil
        heard = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Logs the wait you feel: from the mic closing (polled every 0.25 s) to Handy handing over the text.
    func pasted() {
        if let began {
            let closed = stopped ?? Date()
            log(String(format: "text came %.1fs after the mic closed (%.0fs recording)",
                       Date().timeIntervalSince(closed), closed.timeIntervalSince(began)))
        }
        finish()
    }

    func cancelled() {
        guard began != nil else { return }
        log("recording cancelled")
        finish()
    }

    private func finish() {
        began = nil
        stopped = nil
        finished = Date()
        timer?.invalidate()
        timer = nil
    }

    private var asking = false

    private func tick() {
        guard began != nil, !asking else { return }
        asking = true
        let handy = handyPIDs()
        audioQueue.async {
            let recording = recordingProcesses().contains { handy.contains($0.pid) }
            DispatchQueue.main.async {
                self.asking = false
                self.update(recording: recording)
            }
        }
    }

    private func update(recording: Bool) {
        guard let began else { return }
        if recording { stopped = nil; heard = true; return }
        if stopped == nil { micClosed() }
        let stop = stopped ?? Date()
        stopped = stop
        let length = stop.timeIntervalSince(began)
        guard Date().timeIntervalSince(stop) > quietGrace ?? (15 + length / 10) else { return }
        log("no text came out of a \(Int(length.rounded()))s recording (Handy heard no speech)")
        if !heard { micDead() } else if length >= 1.5 { sound("Funk") }
        finish()
    }
}

/// Reads "Channels: N" after Handy opens Handy Mics (a log entry over several lines).
final class ChannelReader {
    private var openingMics = false
    var quietly = false
    func read(_ line: String) {
        if line.contains(launchMarker) {
            noteHandyChannels(nil)  // a new Handy works it out again at its first recording
        } else if line.contains("Using device: ") {
            openingMics = line.contains("Using device: Ok(\"\(micsName)\")")
            if !openingMics { noteHandyChannels(nil) }  // Handy is on another mic
        } else if openingMics, line.hasPrefix("Channels: ") {
            noteHandyChannels(Int(line.dropFirst("Channels: ".count)), quietly: quietly)
            openingMics = false
        }
    }
}

func runWatch() -> Never {
    log("watching \(handyLogPath)")
    let picker = MicPicker()
    picker.unmuteLeftovers()
    let recordings = Recordings()
    let capture = Capture()
    recordings.micClosed = { capture.stop() }
    // Nov 23: earbuds dropped out mid-day while still plugged in. Handy Mics then gave no sound at all, nothing changed in
    // the device list, and every dictation came out empty until the Mac was restarted. Now the first such recording
    // puts Handy Mics on the Mac's own mic (the earbuds come back when a mic is plugged in or out) and restarts Handy.
    recordings.micDead = {
        sound("Funk")
        guard env["HANDY_ROUTER_HANDY_LOG"] == nil else { log("Handy's mic gave no sound (test: nothing repaired)"); return }
        audioQueue.async {
            let mics = syncMics(macOnly: true)
            DispatchQueue.main.async {
                restartHandy("Handy's mic gave no sound at all (a mic in \(micsName) stopped working); \(mics); restarted Handy")
            }
        }
    }
    let channels = ChannelReader()
    // What the running Handy logged since its launch (the channel count it settled on).
    if let old = try? String(contentsOfFile: handyLogPath, encoding: .utf8) {
        channels.quietly = true
        old.split(separator: "\n").forEach { channels.read(String($0)) }
        channels.quietly = false
        if let heard = handyChannels { log("Handy reads \(heard.count) channel(s) from \(micsName)") }
    }
    // Handy logs "Using device" as it asks macOS for the mic and the start marker once it has it (normally 0.1-0.3 s).
    // On Nov 9 macOS's audio service sat on that request for minutes: the overlay was up and nothing was recorded.
    var opening: Date?
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        guard let since = opening, Date().timeIntervalSince(since) > openingLimit else { return }
        opening = nil
        log("Handy has waited \(Int(openingLimit))s for macOS to open the mic; nothing is being recorded")
        sound("Funk")
    }
    let tail = LogTail(path: handyLogPath) { line in
        channels.read(line)
        if line.contains("Using device: ") { opening = Date() }
        if line.contains(startMarker) {
            opening = nil
            noteStart()
            recordings.started()
            capture.start()
            if pickCloserMic { picker.start(heard: handyChannels) }
        } else if line.contains(pasteMarker) {
            recordings.pasted()
        } else if line.contains(cancelMarker) {
            recordings.cancelled()
            capture.stop()
        }
    }
    tail.start()
    watchMics()
    // Only the real Handy gets restarted, never from a test watcher on a temp log.
    if env["HANDY_ROUTER_HANDY_LOG"] == nil { keepHandyHealthy { recordings.busy } }
    if pickCloserMic { askForMic() }
    RunLoop.main.run()
    exit(0)
}

// MARK: - paste

/// What the paste is doing, for the timeout line in the log.
var stage = "starting"
/// Each Accessibility call gives up after this, instead of the system's 6s.
let axTimeout: Float = 0.75
let pasteDeadline: TimeInterval = 6  // the accurate pass may take up to 2 s of it

/// Handy waits for this process with no time limit, so a hang here (an app that stops answering Accessibility, a clipboard
/// owner that never hands its data over) froze Handy until it was force-quit (Nov 6). Accessibility calls now give up fast,
/// and after 4s the words go on the clipboard and the router quits, whatever it was doing.
func guardAgainstHangs(_ text: String) {
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), axTimeout)  // on the system-wide element: every element
    DispatchQueue.global().asyncAfter(deadline: .now() + pasteDeadline) {
        log("TIMED OUT after \(Int(pasteDeadline))s while \(stage); kept \(text.count) chars on clipboard")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { exit(0) }  // in case the clipboard is what hangs
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        exit(0)
    }
}

/// Reads and forgets the app the current recording started in.
func takeStart() -> Start? {
    defer { try? FileManager.default.removeItem(atPath: statePath) }
    guard let data = FileManager.default.contents(atPath: statePath),
          let start = try? JSONDecoder().decode(Start.self, from: data),
          Date().timeIntervalSince1970 - start.at < maxRecordingAge else { return nil }
    return start
}

/// The app with keyboard focus right now. Accessibility answers live; NSWorkspace needs the run loop to catch up.
func frontApp() -> NSRunningApplication? {
    if AXIsProcessTrusted() {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            var pid: pid_t = 0
            AXUIElementGetPid(value as! AXUIElement, &pid)
            if pid > 0, let app = NSRunningApplication(processIdentifier: pid) { return app }
        }
    }
    RunLoop.current.run(until: Date())
    return NSWorkspace.shared.frontmostApplication
}

/// macOS can decline an activation, so ask twice and check it landed.
func bringFront(_ app: NSRunningApplication) -> Bool {
    func ask() {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app.activate(options: [])
    }
    ask()
    for tick in 1...60 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        if frontApp()?.processIdentifier == app.processIdentifier { return true }
        if tick == 25 { ask() }
    }
    return false
}

/// What to do with the clipboard once the paste is over. Both leave it alone if something else was copied in between.
struct Clip {
    /// Put back what was there before the transcript.
    let restore: () -> Void
    /// Leave the transcript there as an ordinary copy, so Cmd+V and the clipboard manager have it.
    let keep: () -> Void
}

/// Puts the text on the clipboard, marked transient so clipboard managers skip it while it is only on its way to a paste.
func putOnClipboard(_ text: String) -> Clip {
    let pb = NSPasteboard.general
    let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
        let copy = NSPasteboardItem()
        for type in item.types {
            if let data = item.data(forType: type) { copy.setData(data, forType: type) }
        }
        return copy
    }
    pb.clearContents()
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    pb.writeObjects([item])
    let ours = pb.changeCount
    return Clip(restore: {
        guard pb.changeCount == ours else { return }
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved) }
    }, keep: {
        guard pb.changeCount == ours else { return }
        pb.clearContents()
        pb.setString(text, forType: .string)
    })
}

func pressCommandV() {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)  // kVK_ANSI_V
        event?.flags = .maskCommand
        event?.post(tap: .cghidEventTap)
        usleep(12_000)
    }
}

// MARK: - did it land

enum Landing: String {
    case landed = "landed"
    case missed = "no text box took it, kept on clipboard"
    case unknown = "app does not say what has focus, kept on clipboard"
}

func axValue(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
}

/// What has keyboard focus inside the app. Electron apps (Claude, Discord, Slack) only answer once AXManualAccessibility is on,
/// and only while they are in front.
func focusedElement(_ app: NSRunningApplication) -> AXUIElement? {
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    guard let value = axValue(ax, kAXFocusedUIElementAttribute as String),
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

/// The text in the focused element ("" for a button, a list or a page). A huge one (a terminal's scrollback)
/// is read only around the caret, where a paste ends up.
func contents(_ el: AXUIElement, around span: Int) -> String {
    if let count = axValue(el, kAXNumberOfCharactersAttribute as String) as? Int, count > 100_000 {
        guard let sel = axValue(el, kAXSelectedTextRangeAttribute as String), CFGetTypeID(sel) == AXValueGetTypeID() else { return "" }
        var caret = CFRange()
        AXValueGetValue(sel as! AXValue, .cfRange, &caret)
        let from = max(0, caret.location - span)
        var range = CFRange(location: from, length: caret.location - from)
        guard let arg = AXValueCreate(.cfRange, &range) else { return "" }
        var out: CFTypeRef?
        AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, arg, &out)
        return out as? String ?? ""
    }
    return axValue(el, kAXValueAttribute as String) as? String ?? ""
}

/// Whitespace-insensitive, since editors turn newlines and double spaces into their own thing.
func squeeze(_ s: String) -> String {
    s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

/// Presses Cmd+V in the app in front, then watches its focused element for up to half a second until the words show up.
func pasteAndCheck(_ text: String, in app: NSRunningApplication) -> (Landing, Clip) {
    let words = squeeze(text)
    let tail = String(words.suffix(40))
    let span = text.count + 200
    stage = "reading \(label(app))'s text box"
    let before = focusedElement(app).map { squeeze(contents($0, around: span)) }
    stage = "saving the clipboard"
    let clip = putOnClipboard(text)
    stage = "pasting into \(label(app))"
    pressCommandV()
    stage = "checking \(label(app))'s text box"
    var sawFocus = before != nil
    let deadline = Date().addingTimeInterval(0.5)
    repeat {
        usleep(25_000)
        guard let el = focusedElement(app) else { continue }
        sawFocus = true
        let now = squeeze(contents(el, around: span))
        if !tail.isEmpty, now.contains(tail), before.map({ !$0.contains(tail) || now.count > $0.count }) ?? true {
            return (.landed, clip)
        }
    } while Date() < deadline
    return (sawFocus ? .missed : .unknown, clip)
}

/// Tink: the words are sitting on the clipboard instead of in a text box. Funk: a recording gave no text at all.
func sound(_ name: String) {
    guard !dryRun else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    p.arguments = ["/System/Library/Sounds/\(name).aiff"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
}
func settle(_ landing: Landing, _ clip: Clip) {
    switch landing {
    case .landed: clip.restore()
    case .missed: clip.keep(); sound("Tink")
    case .unknown: clip.keep()
    }
}

func runPaste(_ text: String) {
    let began = Date()
    let start = takeStart()
    if env["HANDY_ROUTER_TEST_HANG"] == "1" { stage = "a test hang"; sleep(30) }
    stage = "finding the app in front"
    let current = frontApp()
    var target: NSRunningApplication?
    if let start, let app = NSRunningApplication(processIdentifier: start.pid), !app.isTerminated { target = app }
    let ms = { Int(Date().timeIntervalSince(began) * 1000) }

    guard let target, let current, target.processIdentifier != current.processIdentifier else {
        if dryRun { print("here \(label(current))"); return }
        guard let current else {
            putOnClipboard(text).keep()
            log("nothing in front; kept \(text.count) chars on clipboard")
            return
        }
        let (landing, clip) = pasteAndCheck(text, in: current)
        settle(landing, clip)
        log("pasted \(text.count) chars\(textSource)\(punctuationAdded ? " with punctuation added" : "") into \(label(current)), where it started: \(landing.rawValue), in \(ms())ms")
        return
    }
    if dryRun { print("route \(label(target)) back to \(label(current))"); return }
    stage = "bringing \(label(target)) forward"
    guard bringFront(target) else {
        let (landing, clip) = pasteAndCheck(text, in: current)
        settle(landing, clip)
        log("GAVE UP bringing \(label(target)) forward; pasted \(text.count) chars\(textSource)\(punctuationAdded ? " with punctuation added" : "") into \(label(current)): \(landing.rawValue), in \(ms())ms")
        return
    }
    usleep(180_000)  // let the app put focus back in its text field
    let (landing, clip) = pasteAndCheck(text, in: target)
    stage = "going back to \(label(current))"
    let back = bringFront(current)
    usleep(100_000)
    stage = "putting the clipboard back"
    settle(landing, clip)
    log("pasted \(text.count) chars\(textSource)\(punctuationAdded ? " with punctuation added" : "") into \(label(target)): \(landing.rawValue), back to \(label(current))\(back ? "" : " FAILED") in \(ms())ms")
}

// MARK: - punctuation

let punctuateSocket = env["HANDY_ROUTER_PUNCTUATE"] ?? "\(home)/Library/Application Support/handy-router/punctuate.sock"
var punctuationAdded = false

func wordsOf(_ s: String) -> [String] {
    s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
}

/// Whisper's punctuation comes and goes, so the punctuation helper (punctuate.py, a login agent) puts sentences,
/// commas and capitals back into a long line. Any failure, a reply after 1.5 s, or a reply with different words:
/// the transcript goes out as Handy wrote it.
func punctuated(_ text: String) -> String {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return text }
    defer { close(fd) }
    var limit = timeval(tv_sec: 1, tv_usec: 500_000)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = Array(punctuateSocket.utf8)
    guard path.count < MemoryLayout.size(ofValue: addr.sun_path) else { return text }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, byte) in path.enumerated() { raw[i] = byte }
        raw[path.count] = 0
    }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { return text }
    let out = Array(text.utf8)
    var sent = 0
    while sent < out.count {
        let n = out[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard n > 0 else { return text }
        sent += n
    }
    shutdown(fd, SHUT_WR)
    var reply = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n == 0 { break }
        guard n > 0 else { return text }
        reply.append(contentsOf: buffer[0..<n])
    }
    let result = String(decoding: reply, as: UTF8.self)
    guard !result.isEmpty, wordsOf(result) == wordsOf(text) else { return text }
    punctuationAdded = result != text
    return result
}

// MARK: - accurate pass

/// What the paste line says about where the words came from.
var textSource = ""

/// Asks the accurate-pass helper (accurate.py) for this recording's text, sending Handy's. It answers in ~0.6 s with its
/// own text, or with Handy's when they disagree. No helper, no answer within 2 s, anything off: Handy's text.
func accurate(_ text: String) -> String {
    guard FileManager.default.fileExists(atPath: accurateSocket) else { return text }
    let fd = connectUnix(accurateSocket, timeout: 2.0)
    guard fd >= 0 else { textSource = " (Handy's text: accurate pass not running)"; return text }
    defer { close(fd) }
    guard let body = try? JSONSerialization.data(withJSONObject: ["handy": text]),
          (Data("GET ".utf8) + body + Data("\n".utf8)).withUnsafeBytes({ writeAll(fd, $0) }) else { return text }
    shutdown(fd, SHUT_WR)
    var reply = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n == 0 { break }
        guard n > 0 else { textSource = " (Handy's text: accurate pass too slow)"; return text }
        reply.append(contentsOf: buffer[0..<n])
    }
    guard let answer = try? JSONSerialization.jsonObject(with: Data(reply)) as? [String: Any] else { return text }
    let why = answer["why"] as? String ?? ""
    guard answer["used"] as? String == "accurate", let better = answer["text"] as? String,
          !better.trimmingCharacters(in: .whitespaces).isEmpty else {
        textSource = " (Handy's text: \(why))"
        return text
    }
    textSource = " (accurate pass, \(answer["ms"] as? Int ?? 0)ms)"
    return better
}

// MARK: - main

// A call with text is always a paste: Handy can carry HANDY_ROUTER_MODE=watch in its environment if the watcher
// started it, and on Nov 9 every paste then turned into a second watcher and Handy hung on "Transcribing...".
let calledWithText = CommandLine.arguments.count > 1
switch calledWithText && !["punctuate", "accurate", "decimate"].contains(env["HANDY_ROUTER_MODE"] ?? "") ? nil : env["HANDY_ROUTER_MODE"] {
case "watch": runWatch()
case "mics": print(syncMics()); exit(0)
case "configure": print(configureHandy(binary: Bundle.main.executablePath ?? CommandLine.arguments[0])); exit(0)
case "punctuate": print(punctuated(CommandLine.arguments.dropFirst().joined(separator: " "))); exit(0)  // what a paste would send
case "accurate": print(accurate(CommandLine.arguments.dropFirst().joined(separator: " ")) + textSource); exit(0)
case "decimate":  // test hook: 48 kHz float32 mono on stdin, the 16 kHz the accurate pass gets on stdout
    var d = Decimator()
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let samples = input.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let out = d.run(samples)
    out.withUnsafeBytes { FileHandle.standardOutput.write(Data($0)) }
    exit(0)
default: break
}
let transcript = CommandLine.arguments.dropFirst().joined(separator: " ")
if !transcript.isEmpty {
    guardAgainstHangs(transcript)
    stage = "waiting for the accurate pass"
    let words = accurate(transcript)
    stage = "adding punctuation"
    runPaste(punctuated(words))
}
exit(0)
