import CoreAudio
import Foundation

public enum Transport: String, Codable, Sendable {
    case builtIn = "built-in", usb = "USB", bluetooth = "Bluetooth", hdmi = "HDMI"
    case displayPort = "DisplayPort", airPlay = "AirPlay", thunderbolt = "Thunderbolt"
    case pci = "PCI", virtual = "virtual", aggregate = "aggregate", other = "other"

    init(_ raw: UInt32) {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypePCI: self = .pci
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAggregate: self = .aggregate
        default: self = .other
        }
    }
}

/// An output device as Splitwave shows it (F2).
public struct OutputDevice: Identifiable, Hashable, Sendable {
    public let objectID: AudioObjectID
    public let uid: String
    public let name: String
    public let transport: Transport
    public let isAlive: Bool
    public let isDefault: Bool
    public let channels: Int
    /// For AirPlay: the receivers the device can switch between.
    public let dataSources: [String]

    public var id: String { uid }

    public init(objectID: AudioObjectID, uid: String, name: String, transport: Transport,
                isAlive: Bool, isDefault: Bool, channels: Int, dataSources: [String] = []) {
        self.objectID = objectID
        self.uid = uid
        self.name = name
        self.transport = transport
        self.isAlive = isAlive
        self.isDefault = isDefault
        self.channels = channels
        self.dataSources = dataSources
    }
}

public enum DeviceCatalog {
    /// Prefix of the UIDs of the private aggregate devices Splitwave creates.
    static let aggregateUIDPrefix = "app.splitwave.aggregate."

    public static func defaultOutputID() -> AudioObjectID? {
        let id = try? AudioObject.value(AudioObject.system, kAudioHardwarePropertyDefaultOutputDevice,
                                        initial: AudioObjectID(kAudioObjectUnknown))
        return id == AudioObjectID(kAudioObjectUnknown) ? nil : id
    }

    public static func outputDevices() -> [OutputDevice] {
        let ids = (try? AudioObject.array(AudioObject.system, kAudioHardwarePropertyDevices, of: AudioObjectID.self)) ?? []
        let defaultID = defaultOutputID()
        return ids.compactMap { id in
            let channels = AudioObject.channelCount(id, scope: kAudioObjectPropertyScopeOutput)
            guard channels > 0, let uid = try? AudioObject.string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix(aggregateUIDPrefix) else { return nil }
            let name = ((try? AudioObject.string(id, kAudioObjectPropertyName)) ?? uid)
                .trimmingCharacters(in: .whitespacesAndNewlines)  // e.g. "soundcore Select 4 Go "
            let transport = Transport((try? AudioObject.value(id, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0)
            let alive = ((try? AudioObject.value(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))) ?? 0) != 0
            return OutputDevice(objectID: id, uid: uid, name: name, transport: transport, isAlive: alive,
                                isDefault: id == defaultID, channels: channels,
                                dataSources: transport == .airPlay ? dataSourceNames(id) : [])
        }
    }

    public static func deviceID(forUID uid: String) -> AudioObjectID? {
        let id = try? AudioObject.translate(AudioObject.system, kAudioHardwarePropertyTranslateUIDToDevice,
                                            qualifier: uid as CFString, initial: AudioObjectID(kAudioObjectUnknown))
        return id == AudioObjectID(kAudioObjectUnknown) ? nil : id
    }

    static func dataSourceNames(_ id: AudioObjectID) -> [String] {
        let scope = kAudioObjectPropertyScopeOutput
        guard let sources = try? AudioObject.array(id, kAudioDevicePropertyDataSources, scope, of: UInt32.self) else { return [] }
        return sources.compactMap { source in
            var input = source
            var name: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
            var addr = AudioObject.address(kAudioDevicePropertyDataSourceNameForIDCFString, scope)
            let status = withUnsafeMutablePointer(to: &input) { inPtr in
                withUnsafeMutablePointer(to: &name) { outPtr in
                    var translation = AudioValueTranslation(
                        mInputData: inPtr, mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                        mOutputData: outPtr, mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
                    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &translation)
                }
            }
            guard status == noErr, let name else { return nil }
            return name.takeRetainedValue() as String
        }
    }
}
