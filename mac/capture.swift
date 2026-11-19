// Accurate pass, audio side: while Handy records, the watcher streams the same mic (Handy Mics, mixed to mono, 16 kHz)
// to the accurate-pass helper (accurate.py), which transcribes it in pieces with a stronger model as you talk. At
// paste time the router asks the helper for the text (main.swift, `accurate`). Anything off here only means the
// router pastes Handy's own text, as before.
import AVFoundation
import AudioToolbox

let accurateSocket = env["HANDY_ROUTER_ACCURATE"] ?? "\(home)/Library/Application Support/handy-router/accurate.sock"

/// Opens a Unix socket to `path` with send/receive timeouts; -1 if nobody is listening.
func connectUnix(_ path: String, timeout: Double) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))  // a vanished helper must not kill us
    var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = b } }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if ok != 0 { close(fd); return -1 }
    return fd
}

func writeAll(_ fd: Int32, _ data: UnsafeRawBufferPointer) -> Bool {
    var sent = 0
    while sent < data.count {
        let n = write(fd, data.baseAddress! + sent, data.count - sent)
        if n <= 0 { return false }
        sent += n
    }
    return true
}

/// 48 kHz to 16 kHz: a 48-tap windowed-sinc low-pass (7 kHz), keeping every third sample.
struct Decimator {
    static let taps: [Float] = {
        let n = 48, fc = 7000.0 / 48000.0
        var t = (0..<n).map { i -> Double in
            let x = Double(i) - Double(n - 1) / 2
            let sinc = x == 0 ? 2 * fc : sin(2 * .pi * fc * x) / (.pi * x)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1)) + 0.08 * cos(4 * .pi * Double(i) / Double(n - 1))
            return sinc * w
        }
        let sum = t.reduce(0, +)
        t = t.map { $0 / sum }
        return t.map(Float.init)
    }()
    private var history = [Float](repeating: 0, count: 47)
    private var phase = 0

    mutating func run(_ input: [Float]) -> [Float] {
        let buf = history + input
        var out: [Float] = []
        out.reserveCapacity(input.count / 3 + 1)
        var i = phase
        Decimator.taps.withUnsafeBufferPointer { taps in
            buf.withUnsafeBufferPointer { b in
                while i < input.count {
                    var acc: Float = 0
                    for k in 0..<48 { acc += taps[k] * b[i + k] }
                    out.append(acc)
                    i += 3
                }
            }
        }
        phase = i - input.count
        history = Array(buf.suffix(47))
        return out
    }
}

/// One recording's audio to the helper. Everything that talks to coreaudiod or the socket runs on `control` or in
/// the queue's callbacks on `work`, never on the watcher's main thread.
final class Capture {
    private let control = DispatchQueue(label: "capture-control")
    private let work = DispatchQueue(label: "capture")
    private var queue: AudioQueueRef?
    private var fd: Int32 = -1          // written on `work`, opened and closed on `control` while no queue runs
    private var broken = false          // set on `work` when the helper stops reading; `control` closes the socket
    private var channels = 0
    private var decimator = Decimator()
    private var began = Date()

    /// Called on main at each start marker; ends any earlier capture first.
    func start() { control.async { self.stopHere(); self.startHere() } }

    /// Called on main when Handy's mic closes, the recording is cancelled, or the watcher sees it is over.
    func stop() { control.async { self.stopHere() } }

    private func startHere() {
        guard FileManager.default.fileExists(atPath: accurateSocket),
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,  // asking would wait for a click
              let device = micsDevice() else { return }
        let rate: Float64 = audioValue(device, kAudioDevicePropertyNominalSampleRate, 0)
        guard rate == 48000 else { log("accurate pass skipped: Handy Mics runs at \(Int(rate)) Hz"); return }
        channels = inputChannels(device)
        guard channels > 0 else { return }
        broken = false
        fd = connectUnix(accurateSocket, timeout: 0.5)
        guard fd >= 0 else { return }
        var big: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &big, socklen_t(MemoryLayout<Int32>.size))
        guard "REC\n".utf8CString.dropLast().withUnsafeBytes({ writeAll(fd, $0) }) else { close(fd); fd = -1; return }
        decimator = Decimator()
        began = Date()
        let c = UInt32(channels)
        var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 4 * c, mFramesPerPacket: 1, mBytesPerFrame: 4 * c,
                                                 mChannelsPerFrame: c, mBitsPerChannel: 32, mReserved: 0)
        var q: AudioQueueRef?
        guard AudioQueueNewInputWithDispatchQueue(&q, &format, 0, work, { [weak self] q, buffer, _, _, _ in
            self?.take(buffer.pointee)
            AudioQueueEnqueueBuffer(q, buffer, 0, nil)
        }) == noErr, let q else { close(fd); fd = -1; return }
        var uid = micsUID as CFString
        _ = withUnsafePointer(to: &uid) { AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, $0, UInt32(MemoryLayout<CFString>.size)) }
        for _ in 0..<8 {  // 50 ms each: the last words reach the helper within ~50 ms
            var buffer: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(q, 2400 * 4 * c, &buffer)
            if let buffer { AudioQueueEnqueueBuffer(q, buffer, 0, nil) }
        }
        guard AudioQueueStart(q, nil) == noErr else { AudioQueueDispose(q, true); close(fd); fd = -1; return }
        queue = q
    }

    /// On `control`. Stopping waits for the queue's callbacks, so none writes to a closed socket.
    private func stopHere() {
        if let q = queue { AudioQueueStop(q, true); AudioQueueDispose(q, true) }
        queue = nil
        if fd >= 0 { close(fd) }
        fd = -1
    }

    /// Runs on `work`: mono, 16 kHz, to the helper. A helper that stops reading ends this capture, nothing else.
    private func take(_ buffer: AudioQueueBuffer) {
        guard fd >= 0, !broken, Date().timeIntervalSince(began) < 900 else { return }
        let frames = Int(buffer.mAudioDataByteSize) / (4 * channels)
        let p = buffer.mAudioData.assumingMemoryBound(to: Float.self)
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)
        for f in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += p[f * channels + c] }
            mono[f] = sum * scale
        }
        let out = decimator.run(mono)
        if !out.withUnsafeBytes({ writeAll(fd, $0) }) { broken = true }
    }
}
