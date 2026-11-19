// RESEARCH TOOL (read-only): asks the headphones which A2DP endpoints/codecs they offer, using AVDTP DISCOVER and
// GET_CAPABILITIES only (no configuration, no stream, nothing is changed on the headphones).
// macOS normally holds the AVDTP signalling channel (L2CAP PSM 25), so the tool disconnects the headphones, reconnects
// them and races macOS to open the channel first. This works only sometimes (timing): re-run if it prints no endpoints.
// It briefly interrupts audio. Usage: swiftc -O avdtp-probe.swift -o avdtp-probe && ./avdtp-probe
import IOBluetooth
import Foundation
func hex(_ b: [UInt8]) -> String { b.map{String(format:"%02x",$0)}.joined(separator:" ") }
final class D: NSObject, IOBluetoothL2CAPChannelDelegate {
  func l2capChannelData(_ ch: IOBluetoothL2CAPChannel!, data ptr: UnsafeMutableRawPointer!, length: Int) {
    let b = [UInt8](UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: UInt8.self), count: length)); print("RX:", hex(b))
    if b.count >= 2 && b[1] == 0x01 && (b[0] & 3) == 2 {            // DISCOVER accept: entries of 2 bytes
      var i = 2; while i + 1 < b.count { print("  endpoint seid=\(b[i] >> 2) inUse=\((b[i] >> 1) & 1) media=\(b[i+1] >> 4) tsep=\((b[i+1] >> 3) & 1)==\(((b[i+1] >> 3) & 1) == 1 ? "SNK" : "SRC")"); i += 2 }
    }
    if b.count >= 2 && b[1] == 0x02 && (b[0] & 3) == 2 {            // GET_CAPABILITIES accept: TLVs
      var i = 2; while i + 1 < b.count { let cat = b[i], l = Int(b[i+1]); if i + 2 + l > b.count { break }
        let d = Array(b[(i+2)..<(i+2+l)]); print("  cap category=\(cat) data=\(hex(d))")
        if cat == 7, d.count >= 2 { print("    codec type=0x\(String(d[1], radix:16))", d[1] == 0xFF && d.count >= 8 ? "VENDOR id=0x\(String(format:"%04x", UInt16(d[2]) | UInt16(d[3]) << 8))\(String(format:"%04x", UInt16(d[4]) | UInt16(d[5]) << 8)) codecId=0x\(String(format:"%04x", UInt16(d[6]) | UInt16(d[7]) << 8))" : "") }
        i += 2 + l }
    }
  }
}
guard let dev = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first(where: { ($0.name ?? "").contains("HiTune") }), dev.isConnected() else { print("not connected"); exit(1) }
let del = D(); var ch: IOBluetoothL2CAPChannel?
print("disconnecting..."); _ = dev.closeConnection(); RunLoop.main.run(until: Date().addingTimeInterval(5))
print("connecting..."); _ = dev.openConnection()
var r: IOReturn = kIOReturnError; let t0 = Date()
while Date().timeIntervalSince(t0) < 8 {
  if dev.isConnected() { r = dev.openL2CAPChannelSync(&ch, withPSM: 25, delegate: del); if r == kIOReturnSuccess { break } }
  RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
print("open L2CAP PSM 25:", r == kIOReturnSuccess ? "OK after \(Int(Date().timeIntervalSince(t0)*1000)) ms" : String(format: "fail 0x%x", r))
guard r == kIOReturnSuccess, let c = ch else { exit(1) }
func send(_ p: [UInt8], _ label: String) { var q = p; print("TX \(label):", hex(q)); _ = c.writeSync(&q, length: UInt16(q.count)); RunLoop.main.run(until: Date().addingTimeInterval(1.2)) }
send([0x10, 0x01], "DISCOVER")
for seid in 1...4 { send([UInt8(0x20 + seid) & 0xF0 | 0, 0x02, UInt8(seid << 2)], "GET_CAPABILITIES seid=\(seid)") }
c.close()
