import CoreAudio

/// Shared between the main thread and one chain's IOProc. Plain fields only: the IOProc
/// reads it through a raw pointer, so it never retains, locks or allocates.
public struct RenderState {
    /// Gain the main thread asks for (0...1). Written by the main thread only.
    public var targetGain: Float = 0
    /// Gain applied at the end of the last callback. Written by the IOProc only.
    public var currentGain: Float = 0
    /// Per-frame gain change, sized for a ~30 ms full-scale ramp (F4).
    public var rampStep: Float = RenderState.rampStep(sampleRate: 48_000)
    /// Peak absolute output sample of the last callback, for level meters (F11).
    public var peak: Float = 0
    /// How many of the IOProc's input channels belong to the tap (they come last).
    public var tapChannels: Int = 2
    /// Channel count of each output device, in aggregate order, when a route plays to several
    /// (F12); each gets its own copy of the tap. Zeros: the whole output is one device.
    public var outputChannels: (Int, Int, Int, Int) = (0, 0, 0, 0)

    public static let maxOutputs = 4

    public init() {}

    public static func rampStep(sampleRate: Double, seconds: Double = 0.030) -> Float {
        Float(1.0 / max(1.0, sampleRate * seconds))
    }
}

/// The IOProc's work: copy the tapped app's audio into the output device's buffers.
public enum Renderer {
    public static func render(_ state: UnsafeMutablePointer<RenderState>,
                              input: UnsafePointer<AudioBufferList>,
                              output: UnsafeMutablePointer<AudioBufferList>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        let inTotal = channelCount(inList)
        let tapChannels = min(state.pointee.tapChannels, inTotal)
        let inBase = inTotal - tapChannels
        let outTotal = channelCount(outList)
        let inFrames = tapChannels > 0 ? channel(inList, inBase).frames : 0

        let start = state.pointee.currentGain
        let target = state.pointee.targetGain
        let step = state.pointee.rampStep
        var peak: Float = 0

        for outIndex in 0..<outTotal {
            let out = channel(outList, outIndex)
            guard let dst = out.data else { continue }
            let frames = min(out.frames, inFrames)
            var gain = start
            let (index, deviceChannels) = position(of: outIndex, total: outTotal, in: state.pointee.outputChannels)

            if deviceChannels == 1 && tapChannels >= 2 {
                // Mono output: fold the stereo tap down.
                let left = channel(inList, inBase), right = channel(inList, inBase + 1)
                if let l = left.data, let r = right.data {
                    for f in 0..<frames {
                        gain = approach(gain, target, step)
                        let s = (l[f * left.stride] + r[f * right.stride]) * 0.5 * gain
                        dst[f * out.stride] = s
                        peak = max(peak, abs(s))
                    }
                } else {
                    zero(dst, stride: out.stride, from: 0, to: frames)
                }
            } else if index < tapChannels, let src = channel(inList, inBase + index).data {
                let srcStride = channel(inList, inBase + index).stride
                for f in 0..<frames {
                    gain = approach(gain, target, step)
                    let s = src[f * srcStride] * gain
                    dst[f * out.stride] = s
                    peak = max(peak, abs(s))
                }
            } else {
                // Extra output channels (surround, HDMI) stay silent.
                zero(dst, stride: out.stride, from: 0, to: frames)
            }
            zero(dst, stride: out.stride, from: frames, to: out.frames)
        }

        state.pointee.currentGain = advance(start, target, step: step, frames: inFrames)
        state.pointee.peak = peak
    }

    /// Where flat output channel `index` sits: its index within its device, and that device's
    /// channel count.
    @inline(__always)
    static func position(of index: Int, total: Int, in sizes: (Int, Int, Int, Int)) -> (Int, Int) {
        // Unrolled: an array here would allocate on the real-time thread.
        if sizes.0 == 0 { return (index, total) }
        var start = 0
        if index < start + sizes.0 { return (index - start, sizes.0) }
        start += sizes.0
        if sizes.1 > 0 {
            if index < start + sizes.1 { return (index - start, sizes.1) }
            start += sizes.1
        }
        if sizes.2 > 0 {
            if index < start + sizes.2 { return (index - start, sizes.2) }
            start += sizes.2
        }
        if sizes.3 > 0, index < start + sizes.3 { return (index - start, sizes.3) }
        return (index, total)  // channels past the known devices
    }

    @inline(__always)
    static func approach(_ gain: Float, _ target: Float, _ step: Float) -> Float {
        if gain < target { return min(gain + step, target) }
        if gain > target { return max(gain - step, target) }
        return gain
    }

    @inline(__always)
    static func advance(_ gain: Float, _ target: Float, step: Float, frames: Int) -> Float {
        let delta = step * Float(frames)
        return gain < target ? min(gain + delta, target) : max(gain - delta, target)
    }

    @inline(__always)
    static func zero(_ dst: UnsafeMutablePointer<Float>, stride: Int, from: Int, to: Int) {
        guard from < to else { return }
        for f in from..<to { dst[f * stride] = 0 }
    }

    @inline(__always)
    static func channelCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        var total = 0
        for buffer in list { total += Int(buffer.mNumberChannels) }
        return total
    }

    /// The flat channel `index` across a buffer list: its first sample, interleave stride and frame count.
    @inline(__always)
    static func channel(_ list: UnsafeMutableAudioBufferListPointer, _ index: Int)
        -> (data: UnsafeMutablePointer<Float>?, stride: Int, frames: Int) {
        var remaining = index
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            if remaining < channels {
                guard channels > 0, let raw = buffer.mData else { return (nil, 1, 0) }
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                return (raw.assumingMemoryBound(to: Float.self) + remaining, channels, frames)
            }
            remaining -= channels
        }
        return (nil, 1, 0)
    }
}
