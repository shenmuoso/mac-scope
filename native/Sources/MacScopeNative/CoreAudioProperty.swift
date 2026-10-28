import CoreAudio
import Foundation

enum CoreAudioProperty {
  static func has(
    _ selector: AudioObjectPropertySelector,
    objectID: AudioObjectID,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) -> Bool {
    var address = address(selector, scope: scope, element: element)
    return AudioObjectHasProperty(objectID, &address)
  }

  static func isSettable(
    _ selector: AudioObjectPropertySelector,
    objectID: AudioObjectID,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) -> Bool {
    var address = address(selector, scope: scope, element: element)
    var settable = DarwinBoolean(false)
    guard AudioObjectIsPropertySettable(objectID, &address, &settable) == noErr else { return false }
    return settable.boolValue
  }

  static func value<T>(
    _ selector: AudioObjectPropertySelector,
    objectID: AudioObjectID,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) -> T? {
    var address = address(selector, scope: scope, element: element)
    var size = UInt32(MemoryLayout<T>.size)
    let storage = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { storage.deallocate() }
    guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, storage) == noErr else {
      return nil
    }
    return storage.pointee
  }

  static func set(
    _ value: Float32,
    selector: AudioObjectPropertySelector,
    objectID: AudioObjectID,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) -> Bool {
    setBytes(value, selector: selector, objectID: objectID, scope: scope, element: element)
  }

  static func set(
    _ value: UInt32,
    selector: AudioObjectPropertySelector,
    objectID: AudioObjectID,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) -> Bool {
    setBytes(value, selector: selector, objectID: objectID, scope: scope, element: element)
  }

  static func set(
    _ value: Float64,
    selector: AudioObjectPropertySelector,
    objectID: AudioObjectID,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) -> Bool {
    setBytes(value, selector: selector, objectID: objectID, scope: scope, element: element)
  }

  private static func setBytes<T>(
    _ value: T,
    selector: AudioObjectPropertySelector,
    objectID: AudioObjectID,
    scope: AudioObjectPropertyScope,
    element: AudioObjectPropertyElement
  ) -> Bool {
    var address = address(selector, scope: scope, element: element)
    var value = value
    return withUnsafePointer(to: &value) { pointer in
      AudioObjectSetPropertyData(
        objectID,
        &address,
        0,
        nil,
        UInt32(MemoryLayout<T>.size),
        pointer
      ) == noErr
    }
  }

  static func string(
    _ selector: AudioObjectPropertySelector,
    objectID: AudioObjectID,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) -> String? {
    var address = address(selector, scope: scope, element: element)
    var unmanaged: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &unmanaged)
    guard status == noErr, let unmanaged else { return nil }
    return unmanaged.takeRetainedValue() as String
  }

  static func objectIDs(
    _ selector: AudioObjectPropertySelector,
    objectID: AudioObjectID = AudioObjectID(kAudioObjectSystemObject),
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> [AudioObjectID] {
    var address = address(selector, scope: scope, element: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr, size > 0 else {
      return []
    }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    guard count > 0 else { return [] }
    var values = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
    guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &values) == noErr else {
      return []
    }
    return values.filter { $0 != kAudioObjectUnknown }
  }

  private static func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    element: AudioObjectPropertyElement
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
  }
}
