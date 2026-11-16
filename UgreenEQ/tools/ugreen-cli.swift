// RESEARCH TOOL: standalone command-line client for the UGREEN protocol over Bluetooth RFCOMM (channel 1).
// Usage:  swiftc -O ugreen-cli.swift -o ugreen-cli && ./ugreen-cli            (read-only: prints state)
//          ./ugreen-cli seteq <classic|jazz|electronic|pop|classical|rock|bass|treble>   (changes the EQ preset)
// Requires the headphones to be paired and connected over Bluetooth (found by name, "HiTune").

import IOBluetooth
import Foundation

let eqNames = ["classic":0,"jazz":1,"electronic":2,"pop":3,"classical":4,"rock":5,"bass":6,"treble":7]
func eqName(_ c: Int) -> String { eqNames.first{ $0.value == c }?.key ?? "?(\(c))" }

func crc16(_ d: [UInt8]) -> UInt16 {
  var crc: UInt16 = 0xFFFF
  for b in d { crc ^= UInt16(b); for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 } }
  return crc
}
func packet(_ cmd: UInt8, _ data: [UInt8]) -> [UInt8] {
  var p: [UInt8] = [0xAA,0xBB,0xCC,cmd,UInt8(data.count)] + data
  let c = crc16(Array(p[3...]))
  p += [UInt8(c & 0xFF), UInt8(c >> 8)]
  return p
}
func hex(_ b: [UInt8]) -> String { b.map{String(format:"%02x",$0)}.joined(separator:" ") }

class Delegate: NSObject, IOBluetoothRFCOMMChannelDelegate {
  var buf = [UInt8]()
  func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data ptr: UnsafeMutableRawPointer!, length: Int) {
    let b = [UInt8](UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: UInt8.self), count: length))
    print("RX:", hex(b)); buf += b; parse()
  }
  func parse() {
    // response: DD EE FF cmd status len payload... crc(2)
    while buf.count >= 8, let i = buf.firstIndex(of: 0xDD) {
      buf.removeFirst(i)
      guard buf.count >= 6, buf[1] == 0xEE, buf[2] == 0xFF else { buf.removeFirst(); continue }
      let len = Int(buf[5]); if buf.count < 8 + len { return }
      let cmd = buf[3], status = buf[4], pl = Array(buf[6..<(6+len)])
      print("  response cmd=\(cmd) status=\(status) payload=\(hex(pl))")
      if cmd == 4 && pl.count > 4 {
        print("  battery(guess)=\(pl[0..<3].map{Int($0)}) anc raw=0x\(String(pl[3],radix:16)) EQ=\(eqName(Int(pl[4])))")
      }
      if cmd == 5, let f = pl.first { print("  EQ now:", eqName(Int(f))) }
      buf.removeFirst(8 + len)
    }
  }
}

let args = CommandLine.arguments
guard let dev = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first(where: { ($0.name ?? "").contains("HiTune") }), dev.isConnected() else { print("headphones not connected over Bluetooth"); exit(1) }
let del = Delegate()
var ch: IOBluetoothRFCOMMChannel?
let r = dev.openRFCOMMChannelSync(&ch, withChannelID: 1, delegate: del)
print("open RFCOMM ch1:", r == kIOReturnSuccess ? "OK" : "fail \(r)")
guard r == kIOReturnSuccess, let c = ch else { exit(1) }

func send(_ p: [UInt8], _ label: String) {
  print("TX \(label):", hex(p))
  var q = p
  let rr = c.writeSync(&q, length: UInt16(q.count))
  if rr != kIOReturnSuccess { print("write error", rr) }
  RunLoop.main.run(until: Date().addingTimeInterval(1.5))
}
send(packet(4, [0]), "get device state (read-only)")
if args.count >= 3, args[1] == "seteq", let code = eqNames[args[2].lowercased()] {
  send(packet(5, [UInt8(code)]), "set EQ \(args[2])")
  send(packet(4, [0]), "re-read state")
}
c.close()
