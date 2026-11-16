// RESEARCH TOOL: sets the UGREEN USB output stream to 96 kHz / 24-bit (CoreAudio physical format).
// Usage:  swiftc -O usb-set-96k.swift -o usb-set-96k && ./usb-set-96k   (headphones connected over USB-C)

import CoreAudio
import Foundation
var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var sz: UInt32 = 0; AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz)
var ids = [AudioObjectID](repeating: 0, count: Int(sz)/4); AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids)
for d in ids {
  var na = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  var name: CFString = "" as CFString; var ns = UInt32(MemoryLayout<CFString>.size)
  AudioObjectGetPropertyData(d, &na, 0, nil, &ns, &name)
  guard (name as String).contains("HiTune") else { continue }
  var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
  var ss: UInt32 = 0; AudioObjectGetPropertyDataSize(d, &sa, 0, nil, &ss)
  var streams = [AudioObjectID](repeating: 0, count: Int(ss)/4); AudioObjectGetPropertyData(d, &sa, 0, nil, &ss, &streams)
  guard let st = streams.first else { continue }
  var fa = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyAvailablePhysicalFormats, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  var fs: UInt32 = 0; AudioObjectGetPropertyDataSize(st, &fa, 0, nil, &fs)
  var f = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(), count: Int(fs)/MemoryLayout<AudioStreamRangedDescription>.size)
  AudioObjectGetPropertyData(st, &fa, 0, nil, &fs, &f)
  guard var best = f.map({ $0.mFormat }).filter({ $0.mSampleRate == 96000 && $0.mBitsPerChannel == 24 }).first else { print("no 96k/24 format"); continue }
  var pa = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyPhysicalFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  let r = AudioObjectSetPropertyData(st, &pa, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &best)
  print("set 96000 Hz / 24-bit:", r == 0 ? "OK" : "failed \(r)")
  var cur = AudioStreamBasicDescription(); var cs = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
  AudioObjectGetPropertyData(st, &pa, 0, nil, &cs, &cur)
  print("now:", Int(cur.mSampleRate), "Hz,", cur.mBitsPerChannel, "-bit,", cur.mChannelsPerFrame, "ch")
  break
}
