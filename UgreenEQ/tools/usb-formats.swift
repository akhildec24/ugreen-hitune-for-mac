// RESEARCH TOOL (read-only): lists the PCM formats the UGREEN headphones offer over USB / Bluetooth.
// Usage:  swiftc -O usb-formats.swift -o usb-formats && ./usb-formats

import CoreAudio
import Foundation
func prop<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ def: T) -> T {
  var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  var v = def; var s = UInt32(MemoryLayout<T>.size)
  AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v); return v
}
var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var sz: UInt32 = 0; AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz)
var ids = [AudioObjectID](repeating: 0, count: Int(sz)/4); AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids)
for d in ids {
  var na = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  var name: CFString = "" as CFString; var ns = UInt32(MemoryLayout<CFString>.size)
  AudioObjectGetPropertyData(d, &na, 0, nil, &ns, &name)
  guard (name as String).contains("HiTune") else { continue }
  print("Device:", name)
  for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeInput] {
    var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var ss: UInt32 = 0; AudioObjectGetPropertyDataSize(d, &sa, 0, nil, &ss)
    var streams = [AudioObjectID](repeating: 0, count: Int(ss)/4); AudioObjectGetPropertyData(d, &sa, 0, nil, &ss, &streams)
    for st in streams {
      var fa = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyAvailablePhysicalFormats, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
      var fs: UInt32 = 0; AudioObjectGetPropertyDataSize(st, &fa, 0, nil, &fs)
      var f = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(), count: Int(fs)/MemoryLayout<AudioStreamRangedDescription>.size)
      AudioObjectGetPropertyData(st, &fa, 0, nil, &fs, &f)
      print(scope == kAudioObjectPropertyScopeOutput ? " OUTPUT stream formats:" : " INPUT stream formats:")
      for x in f { print("   \(Int(x.mFormat.mSampleRate)) Hz, \(x.mFormat.mBitsPerChannel)-bit, \(x.mFormat.mChannelsPerFrame) ch") }
    }
  }
}
