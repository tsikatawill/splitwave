// Renders video/demo.html into docs/demo.mp4 (1920×1080, 30 fps) with a synthesized soundtrack.
//
//   swiftc -O video/render.swift -o .build/render-demo && .build/render-demo
//   .build/render-demo --frames 0,8.5,13,19.6,25.5   just write PNG stills of those moments
//
// Each frame: call render(t) in an offscreen WebKit view, snapshot it, pipe the pixels to ffmpeg.
// The music is generated here (an original chord loop with a light beat), plus a click for each
// click in the animation, so the video has nothing to license.
import AppKit
import WebKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let page = root.appendingPathComponent("video/demo.html")
let assets = root.appendingPathComponent("video/assets")
let output = root.appendingPathComponent("docs/demo.mp4")
let width = 1920, height = 1080

// MARK: App icons for the page (not committed: they belong to their makers)

func exportIcons() throws {
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    for (bundleID, name) in [("com.apple.Music", "music"), ("com.google.Chrome", "chrome"), ("org.videolan.vlc", "vlc")] {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            print("warning: \(bundleID) isn't installed; its icon will be missing"); continue
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 256, height: 256)
        guard let tiff = icon.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { continue }
        try png.write(to: assets.appendingPathComponent("\(name).png"))
    }
}

// MARK: Soundtrack

let sampleRate = 48_000.0

func synthesize(duration: Double, clicks: [Double]) -> (left: [Float], right: [Float]) {
    let n = Int(duration * sampleRate)
    var music = [Float](repeating: 0, count: n * 2)   // interleaved, before the intro filter
    var arpBus = [Float](repeating: 0, count: n * 2)  // gets a stereo delay
    var fx = [Float](repeating: 0, count: n * 2)      // clicks: never filtered

    let bpm = 108.0, beat = 60 / bpm, bar = beat * 4
    let lift = 3.6, end = 27.0
    func freq(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }
    func add(_ buf: inout [Float], _ i: Int, _ v: Double, pan: Double = 0) {
        guard i >= 0 && i < n else { return }
        buf[2 * i] += Float(v * (1 - max(0, pan)))
        buf[2 * i + 1] += Float(v * (1 + min(0, pan)))
    }

    // Cmaj7, Am7, Fmaj7, G6: warm and unresolved until the end.
    let chords: [[Double]] = [[48, 55, 59, 64], [45, 52, 55, 60], [41, 48, 52, 57], [43, 50, 52, 59]]
    let bars = Int(ceil(duration / bar))
    for b in 0..<bars {
        let chord = chords[b % 4], t0 = Double(b) * bar
        let last = t0 + bar >= end
        let length = last ? duration - t0 : bar + 0.4
        // Pad: two slightly detuned sines per note.
        for note in chord {
            let f = freq(note + 12)
            for s in 0..<Int(length * sampleRate) {
                let t = Double(s) / sampleRate
                let env = min(1, t / 0.35) * (last ? max(0, 1 - t / length) : min(1, max(0, (length - t) / 0.5)))
                let v = 0.035 * env * (sin(2 * .pi * f * t) + sin(2 * .pi * f * 1.004 * t + 1))
                add(&music, Int((t0 + t) * sampleRate), v)
            }
        }
        if t0 >= end { continue }
        // Bass on beats 1 and 3, once the beat comes in.
        if t0 + 0.01 >= lift - bar {
            for k in [0.0, 2.0] where t0 + k * beat >= lift && t0 + k * beat < end {
                let f = freq(chord[0] - 12)
                for s in 0..<Int(0.5 * sampleRate) {
                    let t = Double(s) / sampleRate
                    let v = 0.2 * exp(-t / 0.25) * tanh(1.6 * sin(2 * .pi * f * t))
                    add(&music, Int((t0 + k * beat + t) * sampleRate), v)
                }
            }
        }
        // Arpeggio: eighth notes up the chord, alternating left and right.
        let pattern = [0, 1, 2, 3, 2, 1, 2, 3]
        for e in 0..<8 {
            let start = t0 + Double(e) * beat / 2
            guard start < end else { break }
            let f = freq(chord[pattern[e]] + 24)
            let amp = start < lift ? 0.07 : 0.1
            for s in 0..<Int(0.45 * sampleRate) {
                let t = Double(s) / sampleRate
                let p = 2 * .pi * f * t
                let v = amp * exp(-t / 0.18) * (sin(p) + sin(3 * p) / 9 + sin(5 * p) / 25)
                add(&arpBus, Int((start + t) * sampleRate), v, pan: e % 2 == 0 ? -0.35 : 0.35)
            }
        }
    }

    // Drums from the lift: kick on 1 and 3, clap on 2 and 4, closed hats on the off-beats.
    var rng = SystemRandomNumberGenerator()
    let noise = (0..<Int(0.3 * sampleRate)).map { _ in Double.random(in: -1...1, using: &rng) }
    var t = lift
    var step = 0
    while t < end {
        let inBar = step % 8
        if inBar == 0 || inBar == 4 {
            for s in 0..<Int(0.3 * sampleRate) {
                let x = Double(s) / sampleRate
                let phase = 2 * .pi * (45 * x + (120 - 45) * 0.06 * (1 - exp(-x / 0.06)))
                add(&music, Int((t + x) * sampleRate), 0.42 * exp(-x / 0.12) * sin(phase))
            }
        }
        if (inBar == 2 || inBar == 6) && t >= 7.0 {
            for s in 0..<Int(0.18 * sampleRate) {
                let x = Double(s) / sampleRate
                let v = 0.09 * exp(-x / 0.05) * (noise[s] - noise[max(0, s - 3)])
                add(&music, Int((t + x) * sampleRate), v)
            }
        }
        if step % 2 == 1 {
            for s in 0..<Int(0.05 * sampleRate) {
                let x = Double(s) / sampleRate
                let v = 0.05 * exp(-x / 0.012) * (noise[s + 2000] - noise[s + 1999])
                add(&music, Int((t + x) * sampleRate), v, pan: 0.2)
            }
        }
        t += beat / 2
        step += 1
    }

    // Stereo delay on the arpeggio, then into the mix.
    let delay = Int(beat * 0.75 * sampleRate)
    for i in 0..<n {
        for c in 0..<2 {
            let j = 2 * i + c
            if i >= delay { arpBus[j] += 0.35 * arpBus[2 * (i - delay) + (1 - c)] }
            music[j] += arpBus[j]
        }
    }

    // "Everything on one speaker": the intro is muffled, and opens up as Splitwave opens.
    var lp: (Double, Double) = (0, 0)
    for i in 0..<n {
        let time = Double(i) / sampleRate
        let open = min(1, max(0, (time - 3.4) / 1.4))
        let cutoff = 700 * pow(18_000 / 700, open)
        let a = 1 - exp(-2 * .pi * cutoff / sampleRate)
        lp.0 += a * (Double(music[2 * i]) - lp.0)
        lp.1 += a * (Double(music[2 * i + 1]) - lp.1)
        music[2 * i] = Float(lp.0)
        music[2 * i + 1] = Float(lp.1)
    }

    // A soft click for every click in the animation.
    for c in clicks {
        for s in 0..<Int(0.03 * sampleRate) {
            let x = Double(s) / sampleRate
            let v = 0.16 * exp(-x / 0.006) * (0.6 * noise[s + 9000] + sin(2 * .pi * 2600 * x))
            add(&fx, Int((c + x) * sampleRate), v)
        }
    }

    var left = [Float](repeating: 0, count: n), right = left
    var peak: Float = 0
    for i in 0..<n {
        let fade = Float(min(1, Double(i) / (0.25 * sampleRate)))
        left[i] = fade * tanhf(music[2 * i] + fx[2 * i])
        right[i] = fade * tanhf(music[2 * i + 1] + fx[2 * i + 1])
        peak = max(peak, abs(left[i]), abs(right[i]))
    }
    let gain = 0.89 / max(peak, 0.001)
    return (left.map { $0 * gain }, right.map { $0 * gain })
}

func writeWAV(_ audio: (left: [Float], right: [Float]), to url: URL) throws {
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let frames = audio.left.count
    data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + frames * 4)); data.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16); u16(1); u16(2); u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 4); u16(4); u16(16)
    data.append(contentsOf: Array("data".utf8)); u32(UInt32(frames * 4))
    for i in 0..<frames {
        for v in [audio.left[i], audio.right[i]] {
            u16(UInt16(bitPattern: Int16(max(-1, min(1, v)) * 32767)))
        }
    }
    try data.write(to: url)
}

// MARK: Frames

@MainActor
final class Renderer: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let window: NSWindow
    private var loaded: CheckedContinuation<Void, Error>?

    override init() {
        let config = WKWebViewConfiguration()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: config)
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.contentView = web
        window.orderFrontRegardless()
        web.navigationDelegate = self
    }

    func load() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loaded = c
            web.loadFileURL(page, allowingReadAccessTo: root)
        }
        _ = try await web.callAsyncJavaScript("await window.ready; return true", contentWorld: .page)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in loaded?.resume(); loaded = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in loaded?.resume(throwing: error); loaded = nil }
    }

    func demoInfo() async throws -> (duration: Double, fps: Int, clicks: [Double]) {
        let info = try await web.callAsyncJavaScript("return window.DEMO", contentWorld: .page) as! [String: Any]
        return ((info["duration"] as! NSNumber).doubleValue, (info["fps"] as! NSNumber).intValue,
                (info["clicks"] as! [NSNumber]).map(\.doubleValue))
    }

    /// The frame at `t` seconds as tightly packed RGBA.
    func frame(at t: Double) async throws -> (pixels: Data, image: CGImage) {
        _ = try await web.callAsyncJavaScript("render(t); document.body.offsetHeight; return 0",
                                              arguments: ["t": t], contentWorld: .page)
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: width, height: height)
        config.snapshotWidth = NSNumber(value: width)
        let image = try await web.takeSnapshot(configuration: config)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "render", code: 1, userInfo: [NSLocalizedDescriptionKey: "No image at t=\(t)"])
        }
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (data, cg)
    }
}

func savePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

@MainActor
func run() async throws {
    try exportIcons()
    let renderer = Renderer()
    try await renderer.load()
    let (duration, fps, clicks) = try await renderer.demoInfo()

    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--frames"), i + 1 < args.count {
        let dir = root.appendingPathComponent(".build/demo-frames")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for t in args[i + 1].split(separator: ",").compactMap({ Double($0) }) {
            try savePNG(try await renderer.frame(at: t).image, to: dir.appendingPathComponent("t\(t).png"))
        }
        print("Wrote stills to \(dir.path)")
        return
    }

    let wav = root.appendingPathComponent(".build/demo-audio.wav")
    try writeWAV(synthesize(duration: duration, clicks: clicks), to: wav)
    print("Soundtrack ready")

    let ffmpeg = Process()
    ffmpeg.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    ffmpeg.arguments = ["-y", "-loglevel", "error",
                        "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(width)x\(height)", "-r", "\(fps)", "-i", "-",
                        "-i", wav.path,
                        "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-pix_fmt", "yuv420p",
                        "-c:a", "aac", "-b:a", "160k", "-shortest", "-movflags", "+faststart", output.path]
    let pipe = Pipe()
    ffmpeg.standardInput = pipe
    try ffmpeg.run()

    let total = Int(duration * Double(fps))
    for f in 0..<total {
        let t = Double(f) / Double(fps)
        let frame = try await renderer.frame(at: t)
        try pipe.fileHandleForWriting.write(contentsOf: frame.pixels)
        if f == Int(9.5 * Double(fps)) {
            try savePNG(frame.image, to: root.appendingPathComponent(".build/demo-poster.png"))
        }
        if f % (fps * 5) == 0 { print("frame \(f)/\(total)") }
    }
    try pipe.fileHandleForWriting.close()
    ffmpeg.waitUntilExit()
    guard ffmpeg.terminationStatus == 0 else { throw NSError(domain: "render", code: 2, userInfo: [NSLocalizedDescriptionKey: "ffmpeg failed"]) }
    print("Wrote \(output.path); poster frame in .build/demo-poster.png (make docs/demo-poster.jpg from it)")
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    do { try await run(); exit(0) } catch { print("error: \(error)"); exit(1) }
}
app.run()
