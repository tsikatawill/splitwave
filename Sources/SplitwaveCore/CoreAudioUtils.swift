import CoreAudio
import Foundation

public struct CoreAudioError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let operation: String

    public var description: String { "\(operation) failed (\(fourCharCode(status)))" }
}

/// Renders an OSStatus as its four-character code when it is one, else as a number.
func fourCharCode(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { UInt8((n >> UInt32($0)) & 0xFF) }
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
    return String(status)
}

func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation()) }
}

/// Thin wrappers over AudioObjectGetPropertyData for the shapes Splitwave reads.
enum AudioObject {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func has(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var addr = address(selector, scope)
        return AudioObjectHasProperty(id, &addr)
    }

    static func value<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         initial: T) throws -> T {
        var addr = address(selector, scope)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
        try check(status, "Read '\(fourCharCode(OSStatus(bitPattern: selector)))' of object \(id)")
        return result
    }

    static func array<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         of _: T.Type = T.self) throws -> [T] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size), "Size of property")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buffer), "Read array property")
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> String {
        var addr = address(selector, scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value), "Read string property")
        guard let value else { return "" }
        return value.takeRetainedValue() as String
    }

    /// Reads a property that takes a qualifier (e.g. translate a PID or a UID to an object).
    static func translate<Q, T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                qualifier: Q, initial: T) throws -> T {
        var addr = address(selector)
        var q = qualifier
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafePointer(to: &q) { qPtr in
            withUnsafeMutablePointer(to: &result) {
                AudioObjectGetPropertyData(id, &addr, UInt32(MemoryLayout<Q>.size), qPtr, &size, $0)
            }
        }
        try check(status, "Translate property")
        return result
    }

    /// Total channel count across a device's streams in one scope.
    static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
