// RESEARCH TOOL (read-only): talks to Jieli's RCSP service (BLE AE00/AE01/AE02) WITHOUT authentication
// and sends GetSystemInfo requests with different attribute masks to see which settings the firmware exposes.
// Finding: attributes 4 and 12 (EQ) are not present on the Max5c, so custom EQ is not available over RCSP.
// Usage:  swiftc -O rcsp-probe.swift -o rcsp-probe && ./rcsp-probe   (headphones connected over Bluetooth)

import Foundation
import CoreBluetooth
func hex(_ d: Data) -> String { d.map{String(format:"%02x",$0)}.joined(separator:" ") }
final class P: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  var c: CBCentralManager!; var p: CBPeripheral?; var wr: CBCharacteristic?; var started = false; var sn: UInt8 = 0x20
  override init(){ super.init(); c = CBCentralManager(delegate:self, queue:nil) }
  func centralManagerDidUpdateState(_ s: CBCentralManager){ if s.state == .poweredOn { c.scanForPeripherals(withServices:nil) } }
  func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData a:[String:Any], rssi: NSNumber){
    if ((a[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "").contains("HiTune"), self.p == nil { print("found"); self.p = p; p.delegate = self; c.stopScan(); c.connect(p) } }
  func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral){ print("connected"); p.discoverServices(nil) }
  func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?){ for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) } }
  func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?){
    for ch in s.characteristics ?? [] {
      if ch.uuid == CBUUID(string:"AE02") { p.setNotifyValue(true, for: ch) }
      if ch.uuid == CBUUID(string:"AE01") { wr = ch }
    }
    if wr != nil && !started { started = true
      let tests: [(String,[UInt8])] = [
        ("C: func=FF mask=FFFFFFFF", [0xFF,0xFF,0xFF,0xFF,0xFF]),
        ("D: func=FF mask=00000010 (attr4 EQ only)", [0xFF,0x00,0x00,0x00,0x10]),
        ("E: func=FF mask=00001000 (attr12 only)", [0xFF,0x00,0x00,0x10,0x00]),
      ]
      for (i,t) in tests.enumerated() { DispatchQueue.main.asyncAfter(deadline: .now()+2+Double(i)*2) { self.send(0x07, t.1, t.0) } }
    }
  }
  func send(_ cmd: UInt8, _ payload: [UInt8], _ label: String){
    sn &+= 1
    let body = [sn] + payload
    var f = Data([0xFE,0xDC,0xBA,0xC0,cmd,UInt8(body.count>>8),UInt8(body.count&0xFF)]); f.append(contentsOf: body); f.append(0xEF)
    print("TX [\(label)]:", hex(f)); p?.writeValue(f, for: wr!, type: .withoutResponse)
  }
  func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?){ if ch.uuid == CBUUID(string:"AE02") { print("RX:", ch.value.map(hex) ?? "nil") } }
}
let x = P(); RunLoop.main.run(until: Date().addingTimeInterval(30)); print("done")
