// iPhone Rig viewer + capture.
//
// Shows the USB-connected iPhone's screen live in a window and writes frames
// to disk so Claude can see them. macOS exposes the iPhone screen as a capture
// device once "screen capture devices" are allowed (what QuickTime uses).
//
// Built into "iPhone Rig.app" by scripts/build-app.sh so macOS can ask for
// camera permission on its own behalf.
//
//   iPhone Rig.app --args run DIR [--fps N]   window + DIR/latest.jpg, DIR/latest.json
//   iphone-capture list                       list capture devices (no permission needed)
//
// Claude writes DIR/marker.json ({"x","y","label","time"} in frame pixels) and the
// window draws a ring there so you can see where it tapped.

import AppKit
import AVFoundation
import CoreImage
import CoreMediaIO
import Foundation
import ImageIO
import UniformTypeIdentifiers

setvbuf(stdout, nil, _IOLBF, 0)
func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func allowScreenCaptureDevices() {
    var addr = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var allow: UInt32 = 1
    CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil,
                              UInt32(MemoryLayout<UInt32>.size), &allow)
}

func allDevices() -> [AVCaptureDevice] {
    let types: [AVCaptureDevice.DeviceType] = [.external, .builtInWideAngleCamera, .continuityCamera]
    var out: [AVCaptureDevice] = []
    for media in [AVMediaType.muxed, AVMediaType.video] {
        let s = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: media, position: .unspecified)
        for d in s.devices where !out.contains(where: { $0.uniqueID == d.uniqueID }) { out.append(d) }
    }
    return out
}

// The iPhone *screen* is a muxed (video + audio) device with model "iOS Device".
// The wireless Continuity Camera also says "iPhone" but is video-only, so it is skipped.
func currentIPhone() -> AVCaptureDevice? {
    allDevices().first { $0.hasMediaType(.muxed) && $0.modelID.lowercased().contains("ios") }
}

func writeJPEG(_ image: CGImage, to path: String, quality: Double = 0.85) -> Bool {
    let tmp = path + ".tmp"
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: tmp) as CFURL,
                                                     UTType.jpeg.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return false }
    return rename(tmp, path) == 0
}

/// An already-encoded file, written whole and then renamed so readers never see half of it.
func writeData(_ data: Data, to path: String) -> Bool {
    let tmp = path + ".tmp"
    guard (try? data.write(to: URL(fileURLWithPath: tmp))) != nil else { return false }
    return rename(tmp, path) == 0
}

func writeText(_ s: String, to path: String) {
    let tmp = path + ".tmp"
    try? s.write(toFile: tmp, atomically: false, encoding: .utf8)
    rename(tmp, path)
}

// MARK: - Capture

final class Capture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let dir: String
    let minInterval: TimeInterval
    let ci = CIContext()
    /// Every frame (USB or AirPlay) is handled on this one serial queue.
    let queue = DispatchQueue(label: "frames")
    var session: AVCaptureSession?
    var device: AVCaptureDevice?
    var last = Date.distantPast
    var count = 0
    var onStatus: ((String) -> Void)?
    var onFrameSize: ((CGSize) -> Void)?

    let writesStrips: Bool

    init(dir: String, fps: Double, writesStrips: Bool) {
        self.dir = dir
        self.minInterval = fps > 0 ? 1.0 / fps : 0
        self.writesStrips = writesStrips
    }

    func start() -> Bool {
        guard session == nil, let d = currentIPhone() else { return session != nil }
        let s = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: d)
            guard s.canAddInput(input) else { return false }
            s.addInput(input)
        } catch {
            onStatus?("Cannot open the iPhone: \(error.localizedDescription)")
            return false
        }
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddOutput(out) else { return false }
        s.addOutput(out)
        session = s
        device = d
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification,
                     AVCaptureSession.interruptionEndedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: s, queue: nil) { note in
                log("session \(note.name.rawValue): \(note.userInfo ?? [:])")
            }
        }
        s.startRunning()
        startedAt = Date()
        onStatus?("")
        log("capturing \(d.localizedName) into \(dir): running=\(s.isRunning) format=\(d.activeFormat.formatDescription)")
        return true
    }

    var drops = 0
    var callbacks = 0
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        drops += 1
        if drops <= 3 || drops % 300 == 0 {
            let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil)
            log("dropped frame #\(drops): \(String(describing: reason))")
        }
    }

    func stop() {
        session?.stopRunning()
        session = nil
        device = nil
    }

    // The iPhone sometimes accepts the session but never starts sending frames
    // ("valeria connection not seen"). Restart the stream until frames arrive,
    // backing off from 10 s to 60 s.
    var startedAt = Date.distantPast
    var lastFrameAt = Date.distantPast
    var retryDelay: TimeInterval = 10

    func restartIfStalled() {
        guard session != nil else { return }
        let quietSince = max(startedAt, lastFrameAt)
        guard Date().timeIntervalSince(quietSince) > retryDelay else { return }
        log("no frames for \(Int(retryDelay)) s, restarting the stream")
        stop()
        retryDelay = min(retryDelay * 2, 60)
        _ = start()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        callbacks += 1
        if callbacks == 1 { log("first sample buffer from the iPhone") }
        lastFrameAt = now
        retryDelay = 10
        guard !airplayConnected, now.timeIntervalSince(last) >= minInterval else { return }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            if callbacks < 5 { log("sample buffer without an image") }
            return
        }
        source = "usb"
        handle(CIImage(cvPixelBuffer: pb), at: now)
    }

    /// Frames from AirPlay (UxPlay) are ignored by the USB path while a client is mirroring.
    var airplayConnected = false
    var source = "usb"
    var meta: (w: Int, h: Int, t: Double)?

    /// One frame from either source. Runs on `queue`. `jpeg` is the same frame already
    /// encoded (AirPlay); it is saved as it is.
    func handle(_ img: CIImage, at now: Date, jpeg: Data? = nil) {
        let fullW = Int(img.extent.width), fullH = Int(img.extent.height)
        last = now
        count += 1
        if count == 1 || count % 600 == 0 { log("frame \(count) \(fullW)x\(fullH) from \(source)") }
        // latest.json is written every frame so readers know the feed is alive.
        let changed = writePreview(img, fullWidth: fullW, time: now)
        if let jpeg {
            // AirPlay sends a frame only when the screen changed, so every one is saved. The
            // thumbnail check (made for the cable's noise) misses small changes such as the
            // status-bar clock or a typed character, which left Claude an outdated screen.
            guard writeData(jpeg, to: (dir as NSString).appendingPathComponent("latest.jpg")) else { return }
            wroteFull = true
        } else if changed || !wroteFull {
            // Cable: the full-size frame is built and encoded only when the screen changed.
            guard let cg = ci.createCGImage(img, from: img.extent),
                  writeJPEG(cg, to: (dir as NSString).appendingPathComponent("latest.jpg")) else { return }
            wroteFull = true
        }
        meta = (fullW, fullH, now.timeIntervalSince1970)
        writeMeta(alive: now)
        let size = CGSize(width: fullW, height: fullH)
        DispatchQueue.main.async { self.onFrameSize?(size) }
    }

    /// latest.json: `time` is when the latest frame arrived, `alive` when the source last
    /// confirmed it is still streaming (AirPlay sends nothing while the screen is still).
    func writeMeta(alive: Date) {
        guard let m = meta else { return }
        writeText("{\"width\": \(m.w), \"height\": \(m.h), \"time\": \(m.t), \"alive\": \(alive.timeIntervalSince1970), "
                  + "\"frame\": \(count), \"source\": \"\(source)\", \"pid\": \(getpid())}",
                  to: (dir as NSString).appendingPathComponent("latest.json"))
    }

    // A 720-px-wide copy for the Claude Code side pane, cut into horizontal strips so each
    // stays small enough for one pane drawing. A strip is re-encoded only when it really
    // changed, and its version tells the pane which strips to reload.
    //
    // The iPhone's capture stream carries slight noise (a still screen differs by a few
    // levels every frame), so change is judged on a small grayscale thumbnail with a
    // tolerance, against the thumbnail of the strip as last encoded.
    static let previewWidth = 720.0
    static let stripCount = 6
    static let thumbScale = 8          // thumbnail = preview / 8 (90 px wide)
    static let pixelTolerance = 24     // one thumbnail pixel moving more than this = change
    static let meanTolerance = 1.2     // or the strip's average moving more than this
    var stripThumb: [[UInt8]?] = Array(repeating: nil, count: Capture.stripCount)
    var stripVersion: [Int] = Array(repeating: 0, count: Capture.stripCount)
    var wroteFull = false

    var previewSize = CGSize.zero

    /// Returns true when any strip changed since it was last written.
    @discardableResult
    func writePreview(_ img: CIImage, fullWidth: Int, time: Date) -> Bool {
        let n = Capture.stripCount
        let k = Capture.thumbScale
        // 1. A tiny grayscale thumbnail of the whole frame (90 px wide), straight from the
        //    capture buffer: cheap enough to make every frame.
        let tw = Int(Capture.previewWidth) / k
        let ts = Double(tw) / Double(fullWidth)
        let tiny = img.transformed(by: CGAffineTransform(scaleX: ts, y: ts))
        guard let tcg = ci.createCGImage(tiny, from: tiny.extent.integral) else { return true }
        let th = tcg.height
        guard let gray = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: tw,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let gdata = { gray.draw(tcg, in: CGRect(x: 0, y: 0, width: tw, height: th)); return gray.data }()
        else { return true }
        let g = gdata.assumingMemoryBound(to: UInt8.self)

        // 2. Which strips moved past the noise tolerance since they were last written.
        var thumbs: [[UInt8]] = []
        var dirty: [Bool] = []
        for i in 0..<n {
            let r0 = i * th / n, r1 = (i + 1) * th / n
            let thumb = Array(UnsafeBufferPointer(start: g + r0 * tw, count: max(0, r1 - r0) * tw))
            var isNew = true
            if let prev = stripThumb[i], prev.count == thumb.count, !thumb.isEmpty {
                var sum = 0, worst = 0
                for j in 0..<thumb.count {
                    let d = abs(Int(thumb[j]) - Int(prev[j]))
                    sum += d
                    if d > worst { worst = d }
                }
                isNew = worst > Capture.pixelTolerance || Double(sum) / Double(thumb.count) > Capture.meanTolerance
            }
            thumbs.append(thumb)
            dirty.append(isNew)
        }

        // 3. Only then build the 720-px preview and encode the strips that changed.
        var changed = false
        if dirty.contains(true) && !writesStrips {
            // No side pane to feed: just remember what the screen looked like.
            for i in 0..<n where dirty[i] { stripThumb[i] = thumbs[i]; stripVersion[i] = count }
            return true
        }
        if !writesStrips { return false }
        if dirty.contains(true) {
            guard let f = CIFilter(name: "CILanczosScaleTransform") else { return true }
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(Capture.previewWidth / Double(fullWidth), forKey: kCIInputScaleKey)
            f.setValue(1.0, forKey: kCIInputAspectRatioKey)
            guard let out = f.outputImage, let small = ci.createCGImage(out, from: out.extent.integral) else { return true }
            previewSize = CGSize(width: small.width, height: small.height)
            let base = small.height / n
            for i in 0..<n where dirty[i] {
                let y = i * base
                let h = i == n - 1 ? small.height - y : base
                guard let part = small.cropping(to: CGRect(x: 0, y: y, width: small.width, height: h)) else { return true }
                // Each strip must fit one pane drawing (128,000 characters as base64): ~92 KB.
                var data: Data?
                for q in [0.8, 0.65, 0.5, 0.35] {
                    data = jpegData(part, quality: q)
                    if let d = data, d.count <= 92_000 { break }
                }
                guard let data else { return true }
                let path = (dir as NSString).appendingPathComponent("preview-\(i).jpg")
                let tmp = path + ".tmp"
                guard (try? data.write(to: URL(fileURLWithPath: tmp))) != nil, rename(tmp, path) == 0 else { return true }
                stripThumb[i] = thumbs[i]
                stripVersion[i] = count
                changed = true
            }
        }

        let pw = Int(previewSize.width), ph = Int(previewSize.height)
        guard pw > 0 else { return changed }
        let base = ph / n
        let strips = (0..<n).map { i -> String in
            let y = i * base
            let h = i == n - 1 ? ph - y : base
            return "{\"y\": \(y), \"h\": \(h), \"v\": \(stripVersion[i])}"
        }
        writeText("{\"width\": \(pw), \"height\": \(ph), \"time\": \(time.timeIntervalSince1970), \"frame\": \(count), \"strips\": [\(strips.joined(separator: ", "))]}",
                  to: (dir as NSString).appendingPathComponent("preview.json"))
        return changed
    }

    func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

// MARK: - AirPlay (UxPlay)

/// pid of the UxPlay child, so SIGTERM can take it down with us.
var uxplayPID: pid_t = 0

/// The iPhone mirrors to "Claude Rig" (Control Center > Screen Mirroring). UxPlay runs as a
/// hidden child process with no window: its GStreamer pipeline encodes each mirrored frame
/// to a JPEG file, which this class reads and hands to `Capture.handle`.
final class AirPlayFeed {
    let capture: Capture
    let binary: String
    let framePath: String
    let fps: Int
    var process: Process?
    var openSockets = Set<Int>()
    var lineBuffer = ""
    var lastMTime = Date.distantPast
    var restartAt = Date.distantPast
    var lastAlive = Date.distantPast
    /// When the current mirroring connection began, and when a frame last arrived. The feed
    /// counts as alive only once a frame has arrived in the current connection: an iPhone can
    /// connect and never send a picture, and then latest.jpg is a frame from an older session.
    var connectedAt = Date.distantPast
    var lastFrameAt = Date.distantPast
    var reportedNoPicture = false
    var onChange: (() -> Void)?
    var onStatus: ((String) -> Void)?

    static let noPicture = "The iPhone is connected to Claude Rig but sends no picture. "
        + "Unlock it, then on the iPhone stop Screen Mirroring and pick Claude Rig again."

    var connected: Bool { !openSockets.isEmpty }

    init(capture: Capture, binary: String, fps: Int) {
        self.capture = capture
        self.binary = binary
        self.fps = fps
        framePath = (capture.dir as NSString).appendingPathComponent("airplay.jpg")
        // A frame file left from before this helper started is not a new frame.
        if let m = (try? FileManager.default.attributesOfItem(atPath: framePath))?[.modificationDate] as? Date {
            lastMTime = m
        }
    }

    func start() {
        guard process == nil, Date() >= restartAt else { return }
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            if restartAt == .distantPast { log("AirPlay off: \(binary) is not built") }
            restartAt = .distantFuture
            return
        }
        // A UxPlay left behind by an earlier helper would hold the ports.
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", binary]
        try? kill.run(); kill.waitUntilExit()

        let p = Process()
        // UxPlay logs with printf, which buffers when writing to a pipe. `script` gives it a
        // pseudo-terminal so each log line (connect / disconnect) arrives at once.
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null", binary,
            "-n", "Claude Rig", "-nh",       // the name the iPhone lists under Screen Mirroring
            "-s", "1080x2340", "-fps", "15", // the phone's own portrait resolution, at most 15 fps
            "-p", "7700",                    // ports 7700-7702: leaves macOS's own receiver alone
            "-as", "0", "-vsync", "no", "-nohold",
            // Software decoding on one thread: each frame comes out as soon as it arrives.
            // The default hardware decoder (vtdec) held the last frame until the next one,
            // so after a tap the screenshot showed the screen *before* it.
            "-avdec", "-vd", "avdec_h264 max-threads=1",
            // AirPlay sends frames only when the screen changes (variable frame rate), so no
            // videorate here: it fails on that. Each frame is encoded once, as it arrives.
            "-vs", "jpegenc quality=85 ! multifilesink location=\(framePath)",
        ]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(s) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                log("uxplay exited (\(proc.terminationStatus)); restarting in 5 s")
                self?.process = nil
                self?.openSockets.removeAll()
                self?.restartAt = Date().addingTimeInterval(5)
                uxplayPID = 0
                self?.onChange?()
            }
        }
        do {
            try p.run()
            process = p
            uxplayPID = p.processIdentifier
            log("AirPlay receiver \"Claude Rig\" started (uxplay pid \(p.processIdentifier))")
        } catch {
            log("could not start uxplay: \(error)")
            restartAt = Date().addingTimeInterval(30)
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    /// UxPlay's log lines tell when the iPhone connects and disconnects.
    func consume(_ s: String) {
        // The pseudo-terminal ends lines with "\r\n", which Swift treats as one Character.
        lineBuffer += s.replacingOccurrences(of: "\r", with: "")
        while let nl = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<nl]).trimmingCharacters(in: .whitespacesAndNewlines)
            lineBuffer.removeSubrange(...nl)
            guard !line.isEmpty else { continue }
            // UxPlay's clock-sync requests over IPv6 link-local fail every few seconds
            // (harmless: mirroring works without them), so keep them out of the log.
            if !line.contains("raop_ntp") { log("uxplay: \(line)") }
            let before = connected
            if line.hasPrefix("Accepted"), let n = socketNumber(line) { openSockets.insert(n) }
            if line.contains("Connection closed on socket") || line.contains("Removing connection for socket"),
               let n = socketNumber(line) { openSockets.remove(n) }
            if before != connected {
                log(connected ? "iPhone is mirroring to Claude Rig" : "iPhone stopped mirroring")
                if connected {
                    connectedAt = Date()
                    reportedNoPicture = false
                }
                onChange?()
            }
        }
    }

    func socketNumber(_ line: String) -> Int? {
        guard let r = line.range(of: "socket ") else { return nil }
        return Int(line[r.upperBound...].prefix { $0.isNumber })
    }

    /// Called at the frame rate: pick up a newly written, complete JPEG.
    func tick() {
        if process == nil { start() }
        guard connected else { return }
        let now = Date()
        if let attrs = try? FileManager.default.attributesOfItem(atPath: framePath),
           let m = attrs[.modificationDate] as? Date, m > lastMTime,
           let data = FileManager.default.contents(atPath: framePath),
           data.count > 4, data[data.count - 2] == 0xFF, data[data.count - 1] == 0xD9,   // whole file written
           let img = CIImage(data: data) {
            lastMTime = m
            lastAlive = now
            lastFrameAt = now
            if reportedNoPicture {
                reportedNoPicture = false
                log("picture arrived")
                onStatus?("")
            }
            capture.queue.async {
                self.capture.source = "airplay"
                self.capture.handle(img, at: now, jpeg: data)
            }
        } else if lastFrameAt < connectedAt {
            // Connected, but no picture yet in this connection: latest.jpg is from an older
            // session, so don't call the feed alive.
            if !reportedNoPicture, now.timeIntervalSince(connectedAt) > 5 {
                reportedNoPicture = true
                log("connected for 5 s with no picture")
                onStatus?(AirPlayFeed.noPicture)
            }
        } else if now.timeIntervalSince(lastAlive) > 0.5 {
            // The screen is still, so no new frames: tell readers the feed is alive anyway.
            lastAlive = now
            capture.queue.async { self.capture.writeMeta(alive: now) }
        }
    }
}

// MARK: - Window

final class ScreenView: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    let overlay = CALayer()
    let ring = CAShapeLayer()
    let label = CATextLayer()
    let status = CATextLayer()
    var frameSize = CGSize(width: 1080, height: 2340)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer!.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspect
        layer!.addSublayer(preview)
        overlay.isGeometryFlipped = true
        layer!.addSublayer(overlay)

        ring.fillColor = NSColor.white.withAlphaComponent(0.25).cgColor
        ring.strokeColor = NSColor.white.cgColor
        ring.lineWidth = 3
        ring.shadowColor = NSColor.black.cgColor
        ring.shadowOpacity = 0.9
        ring.shadowRadius = 2
        ring.shadowOffset = .zero
        ring.opacity = 0
        overlay.addSublayer(ring)

        for t in [label, status] {
            t.contentsScale = 2
            t.alignmentMode = .center
            t.foregroundColor = NSColor.white.cgColor
            t.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            t.fontSize = 12
            t.isWrapped = true
            overlay.addSublayer(t)
        }
        label.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        label.cornerRadius = 6
        label.opacity = 0
        status.fontSize = 14
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.frame = bounds
        overlay.frame = bounds
        status.frame = CGRect(x: 20, y: bounds.height / 2 - 40, width: bounds.width - 40, height: 80)
        CATransaction.commit()
    }

    // Where the video actually sits inside the view (aspect fit), top-left origin.
    var videoRect: CGRect {
        AVMakeRect(aspectRatio: frameSize, insideRect: CGRect(origin: .zero, size: bounds.size))
    }

    func showMarker(x: Double, y: Double, text: String) {
        let r = videoRect
        let p = CGPoint(x: r.minX + CGFloat(x) / frameSize.width * r.width,
                        y: r.minY + CGFloat(y) / frameSize.height * r.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.path = CGPath(ellipseIn: CGRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32), transform: nil)
        ring.opacity = 1
        label.string = text
        let w = min(bounds.width - 20, CGFloat(text.count) * 7.5 + 20)
        label.frame = CGRect(x: (bounds.width - w) / 2, y: bounds.height - 34, width: w, height: 22)
        label.opacity = text.isEmpty ? 0 : 1
        CATransaction.commit()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + 1.0
        fade.duration = 0.6
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        ring.add(fade, forKey: "fade")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let capture: Capture
    let airplay: AirPlayFeed
    let showWindow: Bool
    var window: NSWindow?
    var view: ScreenView?
    var lastMarker: TimeInterval = 0
    var usbAllowed = false

    static let waiting = "Waiting for the iPhone.\nMirror it: Control Center > Screen Mirroring > Claude Rig (or plug in the cable)."

    init(capture: Capture, airplay: AirPlayFeed, showWindow: Bool) {
        self.capture = capture
        self.airplay = airplay
        self.showWindow = showWindow
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if showWindow { makeWindow() }
        capture.onStatus = { [weak self] s in self?.setStatus(s) }
        capture.onFrameSize = { [weak self] size in
            guard let v = self?.view, v.frameSize != size else { return }
            v.frameSize = size
            self?.window?.contentAspectRatio = size
        }
        setStatus(AppDelegate.waiting)

        // AirPlay needs no camera permission: start it straight away.
        airplay.onChange = { [weak self] in self?.airplayChanged() }
        airplay.onStatus = { [weak self] s in self?.setStatus(s) }
        airplay.start()
        Timer.scheduledTimer(withTimeInterval: 1.0 / Double(max(airplay.fps, 1)), repeats: true) { [weak self] _ in
            self?.airplay.tick()
        }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in self.tick() }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in self.pollMarker() }

        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                if !granted {
                    log("Camera access is off: only AirPlay will work. Allow \"iPhone Rig\" in System Settings > Privacy & Security > Camera for the cable.")
                    return
                }
                allowScreenCaptureDevices()
                self.usbAllowed = true
                self.tick()
            }
        }
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let d = note.object as? AVCaptureDevice, d.uniqueID == self.capture.device?.uniqueID else { return }
            log("iPhone disconnected")
            self.capture.stop()
            self.view?.preview.session = nil
            if !self.airplay.connected { self.setStatus(AppDelegate.waiting) }
        }
    }

    func tick() {
        // While the iPhone mirrors over AirPlay, leave the cable alone.
        guard usbAllowed, !airplay.connected else { return }
        capture.restartIfStalled()
        if capture.session == nil, capture.start() {
            view?.preview.session = capture.session
        }
    }

    func airplayChanged() {
        capture.queue.async { self.capture.airplayConnected = self.airplay.connected }
        if airplay.connected {
            capture.stop()
            view?.preview.session = nil
            setStatus("")
        } else {
            setStatus(AppDelegate.waiting)
            capture.retryDelay = 10
        }
    }

    func pollMarker() {
        let path = (capture.dir as NSString).appendingPathComponent("marker.json")
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["time"] as? Double, t > lastMarker else { return }
        lastMarker = t
        guard Date().timeIntervalSince1970 - t < 3 else { return }
        let x = obj["x"] as? Double ?? -100, y = obj["y"] as? Double ?? -100
        view?.showMarker(x: x, y: y, text: obj["label"] as? String ?? "")
    }

    func setStatus(_ s: String) {
        view?.status.string = s
        view?.status.opacity = s.isEmpty ? 0 : 1
        // The pane in Claude Code reads this while there are no frames.
        let msg = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        writeText("{\"status\": \"\(msg)\", \"time\": \(Date().timeIntervalSince1970), \"pid\": \(getpid())}",
                  to: (capture.dir as NSString).appendingPathComponent("status.json"))
    }

    func makeWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 650),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "iPhone Rig"
        w.contentAspectRatio = NSSize(width: 1080, height: 2340)
        let v = ScreenView(frame: w.contentView!.bounds)
        v.autoresizingMask = [.width, .height]
        w.contentView = v
        w.setFrameAutosaveName("iPhoneRigWindow")
        if !w.setFrameUsingName("iPhoneRigWindow") { w.center() }
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        window = w
        view = v
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { showWindow }
}

// MARK: - main

var args = Array(CommandLine.arguments.dropFirst())
// Finder/`open` may add -psn_ arguments; ignore them.
args.removeAll { $0.hasPrefix("-psn_") }
let cmd = args.first ?? "run"
if !args.isEmpty { args.removeFirst() }
func option(_ name: String, _ def: Double) -> Double {
    if let i = args.firstIndex(of: name), i + 1 < args.count, let v = Double(args[i + 1]) { return v }
    return def
}

switch cmd {
case "list":
    allowScreenCaptureDevices()
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    for d in allDevices() {
        print("\(d.localizedName)\t\(d.hasMediaType(.muxed) ? "muxed" : "video")\tmodel=\(d.modelID)\tid=\(d.uniqueID)")
    }

case "run":
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let dir = args.first(where: { !$0.hasPrefix("--") && Double($0) == nil }) ?? "\(home)/iphone-rig/.rig"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let fps = option("--fps", 12)
    let capture = Capture(dir: dir, fps: fps, writesStrips: args.contains("--preview"))
    var uxplay = "\(home)/iphone-rig/vendor/UxPlay/build/uxplay"
    if let i = args.firstIndex(of: "--uxplay"), i + 1 < args.count { uxplay = args[i + 1] }
    let airplay = AirPlayFeed(capture: capture, binary: uxplay, fps: Int(fps))
    let app = NSApplication.shared
    // Runs hidden by default (no window, no Dock icon).
    // `--window` opens the old standalone window, for debugging.
    let showWindow = args.contains("--window")
    let delegate = AppDelegate(capture: capture, airplay: airplay, showWindow: showWindow)
    app.delegate = delegate
    app.setActivationPolicy(showWindow ? .regular : .accessory)
    signal(SIGTERM) { _ in
        if uxplayPID > 0 { kill(uxplayPID, SIGTERM) }
        exit(0)
    }
    app.run()

default:
    print("""
    iPhone Rig.app --args run [DIR] [--fps N] [--window] [--preview] [--uxplay PATH]
    iphone-capture list
    """)
}
