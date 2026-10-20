import CoreAudio
import XCTest
@testable import SplitwaveCore

/// Builds an AudioBufferList from per-buffer interleaved samples, for feeding the renderer.
final class Buffers {
    let list: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutablePointer<Float>] = []

    /// - Parameter layout: one entry per buffer: (channels, frames, fill value per channel).
    init(_ layout: [(channels: Int, frames: Int, fill: [Float])]) {
        list = AudioBufferList.allocate(maximumBuffers: layout.count)
        for (i, b) in layout.enumerated() {
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: b.channels * b.frames)
            for f in 0..<b.frames {
                for c in 0..<b.channels { samples[f * b.channels + c] = b.fill.isEmpty ? 0 : b.fill[c] }
            }
            storage.append(samples)
            list[i] = AudioBuffer(mNumberChannels: UInt32(b.channels),
                                  mDataByteSize: UInt32(b.channels * b.frames * 4), mData: samples)
        }
    }

    deinit {
        storage.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }

    func sample(buffer: Int, frame: Int, channel: Int) -> Float {
        storage[buffer][frame * Int(list[buffer].mNumberChannels) + channel]
    }
}

final class RendererTests: XCTestCase {
    private func state(gain: Float, current: Float? = nil, tapChannels: Int = 2) -> UnsafeMutablePointer<RenderState> {
        let s = UnsafeMutablePointer<RenderState>.allocate(capacity: 1)
        s.initialize(to: RenderState())
        s.pointee.targetGain = gain
        s.pointee.currentGain = current ?? gain
        s.pointee.tapChannels = tapChannels
        return s
    }

    func testCopiesStereoTapAtUnityGain() {
        let s = state(gain: 1); defer { s.deallocate() }
        let input = Buffers([(2, 64, [0.5, -0.25])])
        let output = Buffers([(2, 64, [9, 9])])
        Renderer.render(s, input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        XCTAssertEqual(output.sample(buffer: 0, frame: 10, channel: 0), 0.5)
        XCTAssertEqual(output.sample(buffer: 0, frame: 10, channel: 1), -0.25)
        XCTAssertEqual(s.pointee.peak, 0.5)
    }

    func testTapChannelsAreTheLastInputs() {
        // A sub-device with its own input (e.g. a USB interface) comes before the tap.
        let s = state(gain: 1); defer { s.deallocate() }
        let input = Buffers([(1, 32, [0.9]), (2, 32, [0.1, 0.2])])
        let output = Buffers([(2, 32, [])])
        Renderer.render(s, input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        XCTAssertEqual(output.sample(buffer: 0, frame: 0, channel: 0), 0.1)
        XCTAssertEqual(output.sample(buffer: 0, frame: 0, channel: 1), 0.2)
    }

    func testNonInterleavedOutputAndExtraChannelsSilenced() {
        let s = state(gain: 1); defer { s.deallocate() }
        let input = Buffers([(2, 16, [0.3, 0.4])])
        let output = Buffers([(1, 16, [7]), (1, 16, [7]), (1, 16, [7])])
        Renderer.render(s, input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        XCTAssertEqual(output.sample(buffer: 0, frame: 5, channel: 0), 0.3)
        XCTAssertEqual(output.sample(buffer: 1, frame: 5, channel: 0), 0.4)
        XCTAssertEqual(output.sample(buffer: 2, frame: 5, channel: 0), 0)
    }

    func testMonoOutputFoldsStereo() {
        let s = state(gain: 1); defer { s.deallocate() }
        let input = Buffers([(2, 16, [0.2, 0.6])])
        let output = Buffers([(1, 16, [])])
        Renderer.render(s, input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        XCTAssertEqual(output.sample(buffer: 0, frame: 3, channel: 0), 0.4, accuracy: 1e-6)
    }

    func testGainRampsOverAbout30ms() {
        let sampleRate = 48_000.0
        let s = state(gain: 1, current: 0); defer { s.deallocate() }
        s.pointee.rampStep = RenderState.rampStep(sampleRate: sampleRate)
        let input = Buffers([(2, 512, [1, 1])])
        let output = Buffers([(2, 512, [])])

        Renderer.render(s, input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        // No jump at the start of the ramp.
        XCTAssertLessThan(output.sample(buffer: 0, frame: 0, channel: 0), 0.001)
        XCTAssertLessThan(s.pointee.currentGain, 1)

        // 30 ms = 1440 frames; three 512-frame cycles get there.
        Renderer.render(s, input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        Renderer.render(s, input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        XCTAssertEqual(s.pointee.currentGain, 1)
        XCTAssertEqual(output.sample(buffer: 0, frame: 511, channel: 1), 1)
    }

    func testShortInputZeroesTheRestOfTheOutput() {
        let s = state(gain: 1); defer { s.deallocate() }
        let input = Buffers([(2, 8, [0.5, 0.5])])
        let output = Buffers([(2, 16, [3, 3])])
        Renderer.render(s, input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        XCTAssertEqual(output.sample(buffer: 0, frame: 7, channel: 0), 0.5)
        XCTAssertEqual(output.sample(buffer: 0, frame: 8, channel: 0), 0)
    }
}

final class MultiOutputRendererTests: XCTestCase {
    func testEachDeviceGetsItsOwnCopyOfTheTap() {
        let s = UnsafeMutablePointer<RenderState>.allocate(capacity: 1)
        defer { s.deallocate() }
        s.initialize(to: RenderState())
        s.pointee.targetGain = 1
        s.pointee.currentGain = 1
        // Speakers (2ch) + a mono Bluetooth speaker + HDMI (8ch, only the first two carry sound).
        s.pointee.outputChannels = (2, 1, 8, 0)
        let input = Buffers([(2, 16, [0.2, 0.6])])
        let output = Buffers([(2, 16, [9, 9]), (1, 16, [9]), (8, 16, Array(repeating: 9, count: 8))])
        Renderer.render(s, input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
        XCTAssertEqual(output.sample(buffer: 0, frame: 4, channel: 0), 0.2)
        XCTAssertEqual(output.sample(buffer: 0, frame: 4, channel: 1), 0.6)
        XCTAssertEqual(output.sample(buffer: 1, frame: 4, channel: 0), 0.4, accuracy: 1e-6)
        XCTAssertEqual(output.sample(buffer: 2, frame: 4, channel: 0), 0.2)
        XCTAssertEqual(output.sample(buffer: 2, frame: 4, channel: 1), 0.6)
        XCTAssertEqual(output.sample(buffer: 2, frame: 4, channel: 2), 0)
    }

    func testPositionMapsFlatChannelsToDevices() {
        XCTAssertEqual(Renderer.position(of: 5, total: 8, in: (0, 0, 0, 0)).0, 5)
        XCTAssertTrue(Renderer.position(of: 2, total: 11, in: (2, 1, 8, 0)) == (0, 1))
        XCTAssertTrue(Renderer.position(of: 4, total: 11, in: (2, 1, 8, 0)) == (1, 8))
    }
}
