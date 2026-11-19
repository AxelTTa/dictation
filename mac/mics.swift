// Handy Mics: one input device that holds every real microphone (the Mac's plus earbuds or a USB mic), kept in sync as
// earbuds come and go. While Handy records, the watcher listens to each mic for the first half second of speech and mutes
// the weaker one until the recording ends, so Handy (which averages the device's channels) hears the closer mic alone.
import AppKit
import AVFoundation
import CoreAudio

let micsName = env["HANDY_ROUTER_MICS_NAME"] ?? "Handy Mics"
let micsUID = env["HANDY_ROUTER_MICS_UID"] ?? "local.axel.handy-router.mics"
/// Test hook: leave out mics whose name contains this.
let micsExclude = env["HANDY_ROUTER_MICS_EXCLUDE"]
let systemObject = AudioObjectID(kAudioObjectSystemObject)
/// The Mac's mic runs its own processing and arrives ~27 ms after a USB mic (measured Nov 6: 25 ms from the speaker,
/// 27.5 ms from a voice). Mixed unaligned, the two make an echo that cost Whisper words and punctuation.
let usbMicDelayFrames = 1300
/// Mute the weaker mic only when the stronger one is clearly better; otherwise keep both (aligned, they agree).
let pickMarginDB: Float = 4
/// Off unless HANDY_ROUTER_PICK_MIC=1 (setup.sh turns it on; it needs a one-time microphone permission for Handy Router).
/// Without it Handy Mics stays a mix of all mics, lined up in time.
let pickCloserMic = env["HANDY_ROUTER_PICK_MIC"] == "1"
let mutedPath = env["HANDY_ROUTER_MUTED"] ?? "\(home)/Library/Application Support/handy-router/muted.json"

/// Hardware only: no aggregates, virtual devices, AirPlay or the iPhone's Continuity mic.
let realTransports: Set<UInt32> = [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBluetooth,
                                   kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire,
                                   kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort]

struct Mic {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    var builtIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
}

func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func audioValue<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ fallback: T,
                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T {
    var addr = address(selector, scope)
    var value = fallback
    var size = UInt32(MemoryLayout<T>.size)
    let err = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
    return err == noErr ? value : fallback
}

func audioString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func audioIDs(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var addr = address(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func inputChannels(_ id: AudioObjectID) -> Int {
    var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
}

/// Every hardware microphone, the Mac's own first (it clocks the combined device).
func realMics() -> [Mic] {
    audioIDs(systemObject, kAudioHardwarePropertyDevices).compactMap { id -> Mic? in
        let transport: UInt32 = audioValue(id, kAudioDevicePropertyTransportType, 0)
        guard realTransports.contains(transport), inputChannels(id) > 0,
              let uid = audioString(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = audioString(id, kAudioObjectPropertyName) ?? uid
        if let micsExclude, name.contains(micsExclude) { return nil }
        return Mic(id: id, uid: uid, name: name, transport: transport)
    }.sorted { $0.builtIn && !$1.builtIn }
}

func device(uid: String) -> AudioObjectID? {
    var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
    var cfUID = uid as CFString
    var id = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let err = withUnsafeMutablePointer(to: &cfUID) {
        AudioObjectGetPropertyData(systemObject, &addr, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
    }
    return err == noErr && id != 0 ? id : nil
}

func micsDevice() -> AudioObjectID? { device(uid: micsUID) }

/// Members in channel order, with the delay each one gets.
func composition(_ device: AudioObjectID) -> [String: Any]? {
    var addr = address(kAudioAggregateDevicePropertyComposition)
    var value: Unmanaged<CFDictionary>?
    var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as? [String: Any]
}

func members(_ comp: [String: Any]?) -> [(uid: String, delay: Int)] {
    (comp?[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] ?? []).map {
        ($0[kAudioSubDeviceUIDKey] as? String ?? "", $0[kAudioSubDeviceExtraInputLatencyKey] as? Int ?? 0)
    }
}

/// The Mac's clock leads and the others follow it with drift compensation; USB mics wait for the Mac's processing.
func micEntries(_ mics: [Mic]) -> [[String: Any]] {
    mics.map { mic in
        [kAudioSubDeviceUIDKey: mic.uid, kAudioSubDeviceDriftCompensationKey: mic.uid == mics[0].uid ? 0 : 1,
         kAudioSubDeviceExtraInputLatencyKey: mic.transport == kAudioDeviceTransportTypeUSB ? usbMicDelayFrames : 0]
    }
}

func setRate(_ device: AudioObjectID) {
    var rate: Float64 = 48000
    var addr = address(kAudioDevicePropertyNominalSampleRate)
    AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &rate)
}

/// Creates the combined mic, or rewrites its members in place (never deleting it: Handy forgets a mic that disappears).
@discardableResult
func syncMics() -> String {
    let mics = realMics()
    guard let main = mics.first else { return "no microphones" }
    let entries = micEntries(mics)
    let names = mics.map(\.name).joined(separator: " + ")
    if let device = micsDevice() {
        let current = composition(device)
        let wanted = entries.map { ($0[kAudioSubDeviceUIDKey] as! String, $0[kAudioSubDeviceExtraInputLatencyKey] as! Int) }
        if members(current).elementsEqual(wanted, by: { $0.uid == $1.0 && $0.delay == $1.1 }) { return "\(micsName): \(names)" }
        var comp = current ?? [:]
        comp[kAudioAggregateDeviceSubDeviceListKey] = entries
        comp[kAudioAggregateDeviceMainSubDeviceKey] = main.uid
        var dict = comp as CFDictionary
        var addr = address(kAudioAggregateDevicePropertyComposition)
        let err = withUnsafePointer(to: &dict) { AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<CFDictionary>.size), $0) }
        guard err == noErr else { return "could not update \(micsName) (error \(err))" }
        setRate(device)
        return "\(micsName) now \(names)"
    }
    let description: [String: Any] = [kAudioAggregateDeviceNameKey: micsName, kAudioAggregateDeviceUIDKey: micsUID,
                                      kAudioAggregateDeviceIsPrivateKey: 0, kAudioAggregateDeviceIsStackedKey: 0,
                                      kAudioAggregateDeviceMainSubDeviceKey: main.uid, kAudioAggregateDeviceSubDeviceListKey: entries]
    var device = AudioObjectID(0)
    let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)
    guard err == noErr else { return "could not create \(micsName) (error \(err))" }
    setRate(device)
    return "created \(micsName): \(names)"
}

/// The watcher's coreaudiod calls (device list, which process records, Handy Mics' make-up) run here, off the main
/// thread: coreaudiod can stall for minutes, and the main thread notes starts and repairs Handy.
let audioQueue = DispatchQueue(label: "audio")

/// Re-syncs whenever a device is plugged in or out.
func watchMics() {
    audioQueue.async { log(syncMics()) }
    var pending = false  // only touched on audioQueue
    var addr = address(kAudioHardwarePropertyDevices)
    AudioObjectAddPropertyListenerBlock(systemObject, &addr, audioQueue) { _, _ in
        guard !pending else { return }
        pending = true
        audioQueue.asyncAfter(deadline: .now() + 1) {
            pending = false
            let result = syncMics()
            if !result.hasPrefix(micsName + ":") { log(result) }
        }
    }
}

// MARK: - picking the closer mic

func setMuted(_ uid: String, _ muted: Bool) {
    guard let id = device(uid: uid) else { return }
    var value: UInt32 = muted ? 1 : 0
    var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)
    AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
}

/// The mics this router muted, written down so a crash or restart never leaves one muted for calls.
func rememberMuted(_ uids: [String]) {
    if let data = try? JSONEncoder().encode(uids) { try? data.write(to: URL(fileURLWithPath: mutedPath), options: .atomic) }
}

func unmuteLeftoverMics() {
    guard let data = FileManager.default.contents(atPath: mutedPath),
          let uids = try? JSONDecoder().decode([String].self, from: data), !uids.isEmpty else { return }
    uids.forEach { setMuted($0, false) }
    rememberMuted([])
    log("unmuted \(uids.count) mic(s) left muted by an earlier run")
}

/// Processes recording right now, and from which devices.
func recordingProcesses() -> [(pid: pid_t, devices: [AudioObjectID])] {
    audioIDs(systemObject, kAudioHardwarePropertyProcessObjectList).compactMap { process in
        guard audioValue(process, kAudioProcessPropertyIsRunningInput, UInt32(0)) != 0 else { return nil }
        return (audioValue(process, kAudioProcessPropertyPID, pid_t(0)),
                audioIDs(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput))
    }
}

func handyPIDs() -> Set<pid_t> {
    if let test = env["HANDY_ROUTER_HANDY_PID"].flatMap(Int32.init) { return [test] }  // test hook: a stand-in recorder
    return Set(NSRunningApplication.runningApplications(withBundleIdentifier: handyBundle).map(\.processIdentifier))
}

/// Listens to Handy Mics alongside Handy, one level per mic every 20 ms, and mutes the weaker mic once there is
/// 0.4 s of speech. Unmutes as soon as Handy stops recording.
/// Everything that talks to coreaudiod runs on `control`, never on the watcher's main thread: coreaudiod can stall
/// (Nov 9: a microphone prompt nobody could answer on a locked screen held it for minutes), and a stalled main thread
/// means no start noted and no Handy repaired. A stall here only means no picking: Handy Mics stays mixed.
final class MicPicker {
    private let control = DispatchQueue(label: "mic-picker-control")
    private let work = DispatchQueue(label: "mic-picker")
    // On `control`:
    private var queue: AudioQueueRef?
    private var muted: [String] = []
    private var poll: DispatchSourceTimer?
    // Set on `control` before a queue starts, then read by its callbacks on `work`:
    private var mics: [Mic] = []
    private var channelOwner: [Int] = []   // channel index -> mic index
    private var levels: [[Float]] = []      // per mic, dB per 20 ms frame
    private var pending: [[Float]] = []     // per channel, samples not yet in a frame
    private var decided = false
    private var began = Date()
    // On main:
    private var queued = 0

    /// Called on main when Handy opens the mic; `heard` is what Handy reads (see handyChannels).
    func start(heard: (pid: pid_t, count: Int)?) {
        guard queued == 0 else { log("the mic picker is still waiting on macOS; keeping all mics on"); return }
        queued += 1
        control.async {
            self.stopHere()
            self.startHere(heard: heard)
            DispatchQueue.main.async { self.queued -= 1 }
        }
    }

    func unmuteLeftovers() { control.async { unmuteLeftoverMics() } }

    private func startHere(heard: (pid: pid_t, count: Int)?) {
        // Without the permission the queue would wait for a click on a prompt, and hold up every mic, Handy's too.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let all = realMics()
        guard let device = micsDevice() else { return }
        let mics = members(composition(device)).compactMap { m in all.first { $0.uid == m.uid } }
        guard mics.count > 1 else { return }
        // Muting is only safe when Handy reads every mic. Handy keeps the channel count from its first recording after
        // launch, so with earbuds plugged in later it reads only the Mac's mic, and muting that left it recording silence
        // (Nov 9: a 32 s dictation came out as 10 characters, others as nothing at all).
        let total = inputChannels(device)
        let handy = handyPIDs()
        guard let heard, handy.contains(heard.pid), heard.count == total else {
            log("Handy reads \(heard?.count ?? 0) of the \(total) mic channels until it restarts; keeping all mics on")
            return
        }
        let ours = Set(mics.map(\.id) + [device])
        let others = recordingProcesses().filter { !handy.contains($0.pid) && $0.pid != getpid() && !Set($0.devices).isDisjoint(with: ours) }
        if !others.isEmpty {
            let names = others.map { NSRunningApplication(processIdentifier: $0.pid)?.localizedName ?? "pid \($0.pid)" }
            log("\(names.joined(separator: ", ")) is using a mic too; keeping all mics on")
            return
        }
        self.mics = mics
        channelOwner = mics.enumerated().flatMap { i, mic in Array(repeating: i, count: inputChannels(mic.id)) }
        levels = Array(repeating: [], count: mics.count)
        pending = Array(repeating: [], count: channelOwner.count)
        decided = false
        began = Date()
        guard let q = openQueue(channels: UInt32(channelOwner.count)) else { return }
        queue = q
        // Handy closes the mic when it stops recording (whatever the reason, even "no speech").
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + 0.3, repeating: 0.3)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let handy = handyPIDs()
            if !recordingProcesses().contains(where: { handy.contains($0.pid) }) || Date().timeIntervalSince(self.began) > 900 { self.stopHere() }
        }
        timer.resume()
        poll = timer
    }

    private func openQueue(channels: UInt32) -> AudioQueueRef? {
        var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
                                                 mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        var q: AudioQueueRef?
        guard AudioQueueNewInputWithDispatchQueue(&q, &format, 0, work, { [weak self] q, buffer, _, _, _ in
            self?.take(buffer.pointee)
            AudioQueueEnqueueBuffer(q, buffer, 0, nil)
        }) == noErr, let q else { return nil }
        var uid = micsUID as CFString
        _ = withUnsafePointer(to: &uid) { AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, $0, UInt32(MemoryLayout<CFString>.size)) }
        for _ in 0..<4 {
            var buffer: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(q, 4800 * 4 * channels, &buffer)
            if let buffer { AudioQueueEnqueueBuffer(q, buffer, 0, nil) }
        }
        guard AudioQueueStart(q, nil) == noErr else { AudioQueueDispose(q, true); return nil }
        return q
    }

    /// On `control`. Stopping waits for the queue's callbacks to finish, so none touch the state afterwards.
    private func stopHere() {
        poll?.cancel()
        poll = nil
        if let q = queue { AudioQueueStop(q, true); AudioQueueDispose(q, true) }
        queue = nil
        if !muted.isEmpty {
            muted.forEach { setMuted($0, false) }
            muted = []
            rememberMuted([])
        }
    }

    /// Runs on `work`.
    private func take(_ buffer: AudioQueueBuffer) {
        guard !decided else { return }
        let count = channelOwner.count
        let samples = buffer.mAudioDataByteSize / UInt32(4 * count)
        let p = buffer.mAudioData.assumingMemoryBound(to: Float.self)
        for c in 0..<count {
            for f in 0..<Int(samples) { pending[c].append(p[f * count + c]) }
        }
        while pending[0].count >= 960 {
            var energy = [Float](repeating: 0, count: mics.count)
            for c in 0..<count {
                energy[channelOwner[c]] += pending[c].prefix(960).reduce(0) { $0 + $1 * $1 } / 960
                pending[c].removeFirst(960)
            }
            for m in mics.indices { levels[m].append(10 * log10(energy[m] + 1e-12)) }
        }
        decide()
    }

    /// Floor = each mic's quietest 10%; speech = frames where some mic is 9 dB over its floor; SNR = speech level over floor.
    private func decide() {
        let frames = levels[0].count
        guard frames >= 15 else { return }
        let floors = levels.map { l in l.sorted()[l.count / 10] }
        let speech = (0..<frames).filter { f in mics.indices.contains { levels[$0][f] - floors[$0] > 9 } }
        let waited = Date().timeIntervalSince(began)
        guard speech.count >= 20 || (waited > 2.5 && speech.count >= 8) else {
            if waited > 5 { decided = true }  // no clear speech yet: keep all mics on
            return
        }
        decided = true
        let snr = mics.indices.map { m in speech.map { levels[m][$0] - floors[m] }.reduce(0, +) / Float(speech.count) }
        let best = snr.indices.max { snr[$0] < snr[$1] }!
        let report = mics.indices.map { "\(mics[$0].name) \(Int(snr[$0])) dB" }.joined(separator: ", ")
        let weaker = mics.indices.filter { $0 != best && snr[best] - snr[$0] >= pickMarginDB }.map { mics[$0].uid }
        let bestName = mics[best].name
        control.async {
            guard self.queue != nil else { return }  // Handy already stopped
            if weaker.isEmpty {
                log("kept all mics on (\(report))")
                return
            }
            self.muted = weaker
            rememberMuted(weaker)
            weaker.forEach { setMuted($0, true) }
            log("using \(bestName) (\(report))")
        }
    }
}

/// Asks once for the microphone (the watcher listens to levels only, never stores audio), and only while someone is at
/// the Mac (screen unlocked, a key or the mouse touched in the last 5 s), so the prompt gets answered rather than
/// waiting on a locked screen. Rebuilds keep the answer: build.sh signs by name, not by build.
func askForMic() {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .notDetermined:
        log("will ask for the microphone (to pick the closer mic) once you are at the Mac; until then Handy Mics stays mixed")
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
            guard secondsSinceInput() < 5, NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow" else { return }
            timer.invalidate()
            AVCaptureDevice.requestAccess(for: .audio) { ok in log(ok ? "microphone allowed" : "microphone refused: Handy Mics stays mixed") }
        }
    case .denied, .restricted: log("no microphone permission: Handy Mics stays mixed (allow Handy Router in Privacy > Microphone)")
    default: break
    }
}

// MARK: - Handy's settings

let handyApp = URL(fileURLWithPath: "/Applications/Handy.app")
let handySettingsPath = env["HANDY_ROUTER_HANDY_SETTINGS"] ?? "\(home)/Library/Application Support/com.pais.handy/settings_store.json"
/// Escape alone cancelled recordings whenever it was pressed for something else (closing a popup, a pinyin candidate).
let cancelShortcut = "shift+escape"

func readHandySettings() -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: handySettingsPath),
          let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return doc["settings"] as? [String: Any] ?? doc
}

/// Quits Handy, edits its settings (it keeps them in memory and writes them back, so only while it is closed), reopens it.
func rewriteHandySettings(_ change: (inout [String: Any]) -> Void) {
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: handyBundle) { kill(app.processIdentifier, SIGTERM) }
    for _ in 0..<50 where !NSRunningApplication.runningApplications(withBundleIdentifier: handyBundle).isEmpty {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    if let data = FileManager.default.contents(atPath: handySettingsPath),
       var doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if var settings = doc["settings"] as? [String: Any] {
            change(&settings)
            doc["settings"] = settings
        } else {
            change(&doc)
        }
        if let out = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: handySettingsPath + ".bak-last-router-edit"))
            try? out.write(to: URL(fileURLWithPath: handySettingsPath), options: .atomic)
        }
    }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    // Handy inherits the caller's environment; blank this router's own variables so its pastes stay pastes.
    config.environment = Dictionary(uniqueKeysWithValues: env.keys.filter { $0.hasPrefix("HANDY_ROUTER_") }.map { ($0, "") })
    var opened = false
    NSWorkspace.shared.openApplication(at: handyApp, configuration: config) { _, _ in opened = true }
    for _ in 0..<100 where !opened { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
}

/// Points Handy at this router and at Handy Mics, and moves Cancel off bare Escape. Used by `build.sh install`.
func configureHandy(binary: String) -> String {
    guard let s = readHandySettings() else { return "Handy settings not found" }
    let cancel = ((s["bindings"] as? [String: Any])?["cancel"] as? [String: Any])?["current_binding"] as? String
    if s["paste_method"] as? String == "external_script", s["external_script_path"] as? String == binary,
       s["selected_microphone"] as? String == micsName, cancel != "escape" {
        return "Handy already set up"
    }
    rewriteHandySettings { s in
        s["paste_method"] = "external_script"
        s["external_script_path"] = binary
        s["selected_microphone"] = micsName
        if var bindings = s["bindings"] as? [String: Any], var c = bindings["cancel"] as? [String: Any], c["current_binding"] as? String == "escape" {
            c["current_binding"] = cancelShortcut
            bindings["cancel"] = c
            s["bindings"] = bindings
        }
    }
    return "Handy now pastes through the router, records from \(micsName), cancels on \(cancelShortcut)"
}

/// Whether macOS has switched off Handy's keyboard listener. macOS disables an event tap whose callback stalls
/// (sleep, a busy moment), and Handy never turns it back on: Fn then does nothing (Nov 9, after a night asleep).
func handyKeysOff() -> Bool {
    let handy = handyPIDs()
    var count: UInt32 = 0
    CGGetEventTapList(0, nil, &count)
    var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
    CGGetEventTapList(count, &taps, &count)
    let mine = taps.prefix(Int(count)).filter { handy.contains($0.tappingProcess) && $0.eventsOfInterest & (1 << 12) != 0 }
    return !mine.isEmpty && !mine.contains { $0.enabled }
}

/// How many channels Handy reads from Handy Mics, from its log ("Channels: N" when it opens the mic). Handy works this
/// out at its first recording after launch and keeps it (a per-name cache in its recorder) until it restarts, so when
/// earbuds come or go afterwards it reads only the first mic, or a missing one. Nil: Handy has not recorded since launch.
var handyChannels: (pid: pid_t, count: Int)?

func noteHandyChannels(_ count: Int?, quietly: Bool = false) {
    let now = count.flatMap { c in handyPIDs().first.map { (pid: $0, count: c) } }
    if !quietly, let now, now.pid != handyChannels?.pid || now.count != handyChannels?.count {
        log("Handy reads \(now.count) channel(s) from \(micsName)")
    }
    handyChannels = now
}

/// Seconds since the last key press, click or mouse move anywhere.
func secondsSinceInput() -> Double {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
}

var lastRestart = Date.distantPast

func restartHandy(_ why: String, change: (inout [String: Any]) -> Void = { _ in }) {
    lastRestart = Date()
    rewriteHandySettings(change)
    handyChannels = nil
    log(why)
}

/// Checks Handy every 2 s and restarts it only between dictations (`busy` covers recording, transcribing and the paste):
/// - its Fn listener is off (macOS switches off an event tap that stalls and Handy never turns it back on): right away;
/// - it reads the wrong number of mic channels after earbuds came or went: once nobody has touched the keyboard or
///   mouse for 15 s, so the restart (about 2 s) does not swallow the next Fn press;
/// - it fell back to the default mic: puts Handy Mics back.
/// Other apps using a mic (a call, a recorder) no longer hold this up; before Nov 9 any mic in use did.
func keepHandyHealthy(busy: @escaping () -> Bool) {
    var ticks = 0
    var checking = false
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        ticks += 1
        let handy = handyPIDs()
        guard !checking, !handy.isEmpty, Date().timeIntervalSince(lastRestart) > 60, !busy() else { return }
        checking = true
        let heard = handyChannels
        let checkMic = ticks % 15 == 0
        audioQueue.async {
            let recording = recordingProcesses().contains { handy.contains($0.pid) }
            let total = micsDevice().map(inputChannels)
            DispatchQueue.main.async {
                checking = false
                guard !recording, !busy(), handyPIDs() == handy else { return }
                if handyKeysOff() {
                    restartHandy("macOS had switched off Handy's Fn listener; restarted Handy")
                } else if let heard, let total, handy.contains(heard.pid), heard.count != total, secondsSinceInput() > 15 {
                    restartHandy("Handy was reading \(heard.count) of the \(total) mic channels since a mic came or went; restarted it")
                } else if checkMic, total != nil, let s = readHandySettings(),
                          s["selected_microphone"] == nil || s["selected_microphone"] is NSNull {
                    restartHandy("Handy had fallen back to the default mic; set it back to \(micsName) and restarted it") {
                        $0["selected_microphone"] = micsName
                    }
                }
            }
        }
    }
}
