import CoreAudio
import Foundation

/// One routed app: process tap → private aggregate device (output devices + tap) → IOProc.
///
/// The tap mutes the app on whatever device it was playing to; the IOProc copies the tapped
/// audio into each chosen output. Destroying the chain hands the app back to the system.
public final class RouteChain {
    public let appID: String
    /// The outputs, in order; the first one is the aggregate's clock.
    public let deviceUIDs: [String]
    public private(set) var processObjects: [AudioObjectID]

    /// Called on the main queue when an output's sample rate or channel layout changes, as AirPods
    /// do when a call app starts using their microphone. The chain has to be rebuilt then.
    public var onFormatChange: () -> Void = {}

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapUUID = UUID()
    private let state: UnsafeMutablePointer<RenderState>
    private var formatListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var builtFormats: [AudioObjectID: DeviceFormat] = [:]

    public init(appID: String, processObjects: [AudioObjectID], deviceUIDs: [String], gain: Float) throws {
        precondition(!deviceUIDs.isEmpty)
        self.appID = appID
        self.deviceUIDs = Array(deviceUIDs.prefix(RenderState.maxOutputs))
        self.processObjects = processObjects
        state = .allocate(capacity: 1)
        state.initialize(to: RenderState())
        state.pointee.targetGain = gain

        do {
            try build()
        } catch {
            teardown()
            throw error
        }
    }

    deinit {
        teardown()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    /// 0...1, ramped by the IOProc.
    public var gain: Float {
        get { state.pointee.targetGain }
        set { state.pointee.targetGain = max(0, min(1, newValue)) }
    }

    /// Peak output level of the most recent IO cycle.
    public var peak: Float { state.pointee.peak }

    private func build() throws {
        let description = tapDescription(processObjects)
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Create process tap for \(appID)")

        let tapFormat = try AudioObject.value(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0, tapFormat.mBitsPerChannel == 32 else {
            throw CoreAudioError(status: OSStatus(kAudioHardwareUnsupportedOperationError),
                                 operation: "Tap format for \(appID) is not 32-bit float")
        }
        state.pointee.tapChannels = Int(tapFormat.mChannelsPerFrame)

        let aggregateUID = DeviceCatalog.aggregateUIDPrefix + UUID().uuidString
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Splitwave \(appID)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUIDs[0],
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            // Extra outputs run on their own clocks; resample them onto the first one's.
            kAudioAggregateDeviceSubDeviceListKey: deviceUIDs.enumerated().map { i, uid in
                [kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: i > 0] as [String: Any]
            },
            kAudioAggregateDeviceTapListKey: [
                // The tap runs on the clock of the device the app plays to; resample it
                // onto the output's clock so long sessions don't drift.
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID),
                  "Create aggregate device for \(appID)")

        try waitUntilAlive(aggregateID)

        let sampleRate = (try? AudioObject.value(aggregateID, kAudioDevicePropertyNominalSampleRate,
                                                 initial: Float64(0))) ?? 0
        state.pointee.rampStep = RenderState.rampStep(sampleRate: sampleRate > 0 ? sampleRate : tapFormat.mSampleRate)

        // Tell the renderer where each output's channels sit in the aggregate (they follow the
        // sub-device order), so every device gets the tap on its first channels.
        let deviceIDs = deviceUIDs.compactMap(DeviceCatalog.deviceID(forUID:))
        let counts = deviceIDs.map { AudioObject.channelCount($0, scope: kAudioObjectPropertyScopeOutput) }
        if counts.count > 1 {
            let c = counts + [0, 0, 0, 0]
            state.pointee.outputChannels = (c[0], c[1], c[2], c[3])
        }

        try check(AudioDeviceCreateIOProcID(aggregateID, renderProc, UnsafeMutableRawPointer(state), &ioProcID),
                  "Create IOProc for \(appID)")

        var lastStatus: OSStatus = noErr
        for attempt in 0..<4 {
            lastStatus = AudioDeviceStart(aggregateID, ioProcID)
            if lastStatus == noErr { break }
            Thread.sleep(forTimeInterval: 0.05 * Double(1 << attempt))
        }
        try check(lastStatus, "Start audio for \(appID)")

        // Recorded after starting, so changes the aggregate itself makes don't count.
        for id in deviceIDs { builtFormats[id] = DeviceFormat(id) }
        watchFormats(of: deviceIDs)
    }

    /// An output's nominal sample rate and output channel count.
    private struct DeviceFormat: Equatable {
        let sampleRate: Float64
        let channels: Int

        init(_ id: AudioObjectID) {
            sampleRate = (try? AudioObject.value(id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))) ?? 0
            channels = AudioObject.channelCount(id, scope: kAudioObjectPropertyScopeOutput)
        }
    }

    private func watchFormats(of deviceIDs: [AudioObjectID]) {
        let properties = [
            AudioObject.address(kAudioDevicePropertyNominalSampleRate),
            AudioObject.address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
        ]
        for id in deviceIDs {
            for property in properties {
                var addr = property
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.checkFormat(of: id) }
                if AudioObjectAddPropertyListenerBlock(id, &addr, .main, block) == noErr {
                    formatListeners.append((id, property, block))
                }
            }
        }
    }

    private func checkFormat(of id: AudioObjectID) {
        guard let built = builtFormats[id] else { return }
        let now = DeviceFormat(id)
        // A device that just disappeared reads as 0 Hz; the device list change handles that.
        guard now.sampleRate > 0, now != built else { return }
        builtFormats[id] = now
        onFormatChange()
    }

    /// Points the existing tap at a new set of processes (Chrome starting a new audio helper)
    /// without touching the aggregate or the IOProc, so audio keeps flowing.
    public func updateProcesses(_ objects: [AudioObjectID]) throws {
        var description = tapDescription(objects)
        var addr = AudioObject.address(kAudioTapPropertyDescription)
        let status = withUnsafeMutablePointer(to: &description) {
            AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        try check(status, "Update tap processes for \(appID)")
        processObjects = objects
    }

    /// Same UUID every time: the aggregate device refers to the tap by it.
    private func tapDescription(_ objects: [AudioObjectID]) -> CATapDescription {
        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.uuid = tapUUID
        description.name = "Splitwave \(appID)"
        description.isPrivate = true
        description.muteBehavior = .muted
        return description
    }

    /// A freshly made aggregate can take a moment before it accepts IO.
    private func waitUntilAlive(_ id: AudioObjectID) throws {
        for attempt in 0..<6 {
            let alive = (try? AudioObject.value(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))) ?? 0
            if alive != 0 { return }
            Thread.sleep(forTimeInterval: 0.02 * Double(1 << attempt))
        }
        throw CoreAudioError(status: OSStatus(kAudioHardwareNotRunningError),
                             operation: "Aggregate device for \(appID) never came alive")
    }

    private func teardown() {
        for (id, property, block) in formatListeners {
            var addr = property
            AudioObjectRemovePropertyListenerBlock(id, &addr, .main, block)
        }
        formatListeners.removeAll()
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

/// Runs on Core Audio's real-time thread: no allocation, locks, logging or Objective-C.
private let renderProc: AudioDeviceIOProc = { _, _, inputData, _, outputData, _, clientData in
    guard let clientData else { return noErr }
    Renderer.render(clientData.assumingMemoryBound(to: RenderState.self), input: inputData, output: outputData)
    return noErr
}
