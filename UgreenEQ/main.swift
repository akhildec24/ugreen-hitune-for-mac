import Cocoa
import IOBluetooth
import CoreBluetooth
import SwiftUI

// UGREEN HiTune Max5c menu bar controller.
// Protocol (from Gadgetbridge's UGREEN support): RFCOMM channel 1,
// request  AA BB CC <cmd> <len> <data...> <crc16 LE>  (CRC-16/ARC-style, init 0xFFFF, poly 0xA001, over cmd..data)
// response DD EE FF <cmd> <status> <len> <payload...> <crc16>

let eqPresets: [(name: String, code: UInt8)] = [
    ("Classic", 0), ("Jazz", 1), ("Electronic", 2), ("Pop", 3),
    ("Classical", 4), ("Rock", 5), ("Bass", 6), ("Treble", 7),
]
let ancModes: [(name: String, raw: UInt8)] = [
    ("Off", 0xD0), ("Light", 0xC1), ("Medium", 0xB1), ("Deep", 0xA1),
    ("Adaptive", 0xD1), ("Transparency", 0xD2),
]

func ancName(_ raw: UInt8) -> String {
    switch raw {
    case 0, 0xA0, 0xB0, 0xC0, 0xD0: return "Off"
    case 2, 0xA2, 0xB2, 0xC2, 0xD2: return "Transparency"
    case 0xA1: return "Deep"
    case 0xB1: return "Medium"
    case 0xC1: return "Light"
    default: return "Adaptive"
    }
}

// SF Symbols for menu items (looked up by title).
let symbols: [String: String] = [
    // sound presets
    "Classic": "building.columns", "Jazz": "pianokeys", "Electronic": "bolt.fill", "Pop": "sparkles",
    "Classical": "music.quarternote.3", "Rock": "guitars", "Bass": "speaker.wave.3.fill", "Treble": "tuningfork",
    // noise control
    "Off": "speaker.slash", "Light": "dial.low", "Medium": "dial.medium", "Deep": "dial.high",
    "Adaptive": "wand.and.stars", "Transparency": "ear.and.waveform",
    // features
    "Spatial audio": "move.3d", "Game mode (low latency)": "gamecontroller",
    "Dual connection": "link", "High-quality decoding": "hifispeaker",
    // actions
    "Save current settings as profile…": "plus.circle", "Delete profile": "trash",
    "Refresh": "arrow.clockwise", "Quit": "power",
]
func sym(_ name: String?) -> NSImage? {
    guard let name = name, let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
    img.isTemplate = true
    return img
}
func batterySymbol(_ pct: Int) -> String {
    switch pct { case 88...: return "battery.100"; case 63...: return "battery.75"; case 38...: return "battery.50"; case 13...: return "battery.25"; default: return "battery.0" }
}

func crc16(_ d: [UInt8]) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for b in d { crc ^= UInt16(b); for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 } }
    return crc
}
func packet(_ cmd: UInt8, _ data: [UInt8]) -> [UInt8] {
    var p: [UInt8] = [0xAA, 0xBB, 0xCC, cmd, UInt8(data.count)] + data
    let c = crc16(Array(p[3...]))
    p += [UInt8(c & 0xFF), UInt8(c >> 8)]
    return p
}

struct HPState { var battery: Int; var anc: UInt8; var eq: UInt8; var dual = false; var game = false; var hq = false; var spatial = false }

struct Profile: Codable { var name: String; var eq: UInt8; var anc: UInt8 }

func eqLabel(_ code: UInt8) -> String { eqPresets.first { $0.code == code }?.name ?? "?" }
func ancRawForCurrent(_ raw: UInt8) -> UInt8 { ancModes.first { $0.name == ancName(raw) }?.raw ?? 0xD1 }

final class Headphones: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private(set) var state: HPState?
    var onChange: (() -> Void)?

    private var buf = [UInt8]()
    private var channel: IOBluetoothRFCOMMChannel?
    private var opening = false
    private var queue: [[UInt8]] = []
    private var inflight: [UInt8]?
    private var attempts = 0
    private var timeout: Timer?

    func device() -> IOBluetoothDevice? {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?
            .first { ($0.name ?? "").contains("HiTune") }
    }
    var isConnected: Bool { device()?.isConnected() ?? false }

    // MARK: public API (never blocks; commands are queued and sent one at a time)
    func refresh() { enqueue([packet(4, [0])], onlyIfIdle: true) }
    func setEQ(_ code: UInt8) { enqueue([packet(5, [code]), packet(4, [0])]) }
    func setANC(_ raw: UInt8) { enqueue([packet(9, [raw]), packet(4, [0])]) }
    func setToggle(_ cmd: UInt8, _ on: Bool) { enqueue([packet(cmd, [on ? 1 : 0]), packet(4, [0])]) }
    func apply(_ p: Profile) { enqueue([packet(5, [p.eq]), packet(9, [p.anc]), packet(4, [0])]) }

    // MARK: queue
    private func enqueue(_ ps: [[UInt8]], onlyIfIdle: Bool = false) {
        guard isConnected else { fail(); return }
        if onlyIfIdle && (!queue.isEmpty || inflight != nil) { return }
        queue += ps
        pump()
    }

    private func pump() {
        guard inflight == nil, !queue.isEmpty else { return }
        guard let c = channel, c.isOpen() else { openAsync(); return }
        inflight = queue.removeFirst(); attempts = 0
        send()
    }

    private func send() {
        guard let c = channel, var p = inflight else { return }
        if c.writeSync(&p, length: UInt16(p.count)) != kIOReturnSuccess { fail(); return }
        timeout?.invalidate()
        let t = Timer(timeInterval: attempts == 0 ? 0.6 : 1.0, repeats: false) { [weak self] _ in self?.timedOut() }
        RunLoop.main.add(t, forMode: .common)
        timeout = t
    }

    private func timedOut() { attempts += 1; if attempts < 2 { send() } else { fail() } }

    /// Give up on everything pending and drop the channel; the next command reconnects.
    private func fail() {
        timeout?.invalidate(); timeout = nil
        inflight = nil; queue.removeAll(); opening = false
        let c = channel; channel = nil; c?.close()
        onChange?()
    }

    private func openAsync() {
        guard !opening else { return }
        guard let dev = device(), dev.isConnected() else { fail(); return }
        opening = true
        var ch: IOBluetoothRFCOMMChannel?
        if dev.openRFCOMMChannelAsync(&ch, withChannelID: 1, delegate: self) != kIOReturnSuccess { fail(); return }
        channel = ch
        let t = Timer(timeInterval: 4.0, repeats: false) { [weak self] _ in if self?.opening == true { self?.fail() } }
        RunLoop.main.add(t, forMode: .common)
    }

    // MARK: IOBluetoothRFCOMMChannelDelegate
    func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        opening = false
        if error == kIOReturnSuccess { pump() } else { fail() }
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        if ch == channel { channel = nil; if inflight != nil || !queue.isEmpty { fail() } }
    }

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data ptr: UnsafeMutableRawPointer!, length: Int) {
        buf += [UInt8](UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: UInt8.self), count: length))
        var changed = false
        while buf.count >= 8 {
            guard let i = buf.firstIndex(of: 0xDD) else { buf.removeAll(); break }
            buf.removeFirst(i)
            guard buf.count >= 6 else { break }
            guard buf[1] == 0xEE, buf[2] == 0xFF else { buf.removeFirst(); continue }
            let len = Int(buf[5])
            if buf.count < 8 + len { break }
            let cmd = buf[3], pl = Array(buf[6..<(6 + len)])
            buf.removeFirst(8 + len)
            if cmd == 4, pl.count > 4 {
                var st = HPState(battery: Int(pl[0]), anc: pl[3], eq: pl[4])
                if pl.count > 5 { st.dual = pl[5] == 1 }
                if pl.count > 6 { st.game = pl[6] == 1 }
                if pl.count > 7 { st.hq = pl[7] == 1 }
                if pl.count > 20 { st.spatial = pl[20] == 1 }
                state = st
            }
            changed = true
            if let p = inflight, p[3] == cmd {      // reply to the packet we are waiting for
                timeout?.invalidate(); timeout = nil
                inflight = nil; attempts = 0
            }
        }
        if changed { onChange?(); pump() }
    }
}


// MARK: - Battery over Jieli RCSP (BLE)
// The UGREEN protocol's battery byte is stuck at 100 on this firmware, so the real level is read from the
// chip's own RCSP service (BLE AE00/AE01/AE02, GetSystemInfo attribute 0). Read-only, no pairing needed.
final class BatteryReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onLevel: ((Int?) -> Void)?
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var write: CBCharacteristic?
    private var sn: UInt8 = 0x40
    private var scanning = false

    override init() { super.init(); central = CBCentralManager(delegate: self, queue: nil) }

    /// Ask for the battery level; the reply arrives through `onLevel`.
    func request() {
        guard central.state == .poweredOn else { return }
        if let p = peripheral, p.state == .connected, let w = write {
            sn &+= 1
            let body: [UInt8] = [sn, 0xFF, 0x00, 0x00, 0x00, 0x01]   // func FF, attribute mask bit 0 = battery
            var f = Data([0xFE, 0xDC, 0xBA, 0xC0, 0x07, UInt8(body.count >> 8), UInt8(body.count & 0xFF)])
            f.append(contentsOf: body); f.append(0xEF)
            p.writeValue(f, for: w, type: .withoutResponse)
        } else if peripheral == nil || peripheral?.state == .disconnected { startScan() }
    }
    private static let idKey = "rcspPeripheralID"
    private func startScan() {
        // Known headphones: connect directly (pending until they advertise, no scanning needed).
        if peripheral == nil, let str = UserDefaults.standard.string(forKey: Self.idKey), let id = UUID(uuidString: str),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = p; p.delegate = self; central.connect(p); return
        }
        guard !scanning else { return }
        scanning = true; central.scanForPeripherals(withServices: nil)
        // The chip advertises only intermittently: scan in short windows with pauses instead of continuously.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self = self, self.scanning else { return }
            self.central.stopScan(); self.scanning = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                if self?.peripheral == nil { self?.startScan() }
            }
        }
    }
    func centralManagerDidUpdateState(_ c: CBCentralManager) { if c.state == .poweredOn { startScan() } }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData a: [String: Any], rssi: NSNumber) {
        let name = (a[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        guard name.contains("HiTune"), peripheral == nil || peripheral?.state == .disconnected else { return }
        c.stopScan(); scanning = false
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.idKey)
        peripheral = p; p.delegate = self; c.connect(p)
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([CBUUID(string: "AE00")]) }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { peripheral = nil; write = nil; startScan() }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { peripheral = nil; write = nil; onLevel?(nil); startScan() }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics([CBUUID(string: "AE01"), CBUUID(string: "AE02")], for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == CBUUID(string: "AE02") { p.setNotifyValue(true, for: ch) }
            if ch.uuid == CBUUID(string: "AE01") { write = ch }
        }
        request()
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == CBUUID(string: "AE02"), let d = ch.value else { return }
        let b = [UInt8](d)
        // frame: FE DC BA flag cmd lenHi lenLo | status sn func | attrs... | EF ; attr = len, type, data
        guard b.count > 11, b[0] == 0xFE, b[4] == 0x07 else { return }
        var i = 10
        while i < b.count - 1 {
            let l = Int(b[i]); if l == 0 { i += 1; continue }
            if i + l >= b.count { break }
            if b[i + 1] == 0, l >= 2 { onLevel?(Int(b[i + 2] & 0x7F)); return }   // bit 7 is probably "charging"
            i += 1 + l
        }
    }
}

// MARK: - Model

final class Model: ObservableObject {
    let hp = Headphones()
    let battery = BatteryReader()
    @Published var batteryLevel: Int?
    private var lastBattery = Date.distantPast
    private var rfcommAllowed = false
    private var gateTimer: Timer?
    @Published var state: HPState?
    @Published var connected = false
    @Published var profiles: [Profile] = []
    static let key = "profiles"

    let features: [(title: String, icon: String, cmd: UInt8, key: WritableKeyPath<HPState, Bool>)] = [
        ("Spatial audio", "move.3d", 18, \.spatial),
        ("Game mode", "gamecontroller", 8, \.game),
        ("Dual connect", "link", 6, \.dual),
        ("Hi-Q decoding", "hifispeaker", 11, \.hq),
    ]

    init() {
        hp.onChange = { [weak self] in self?.sync() }
        battery.onLevel = { [weak self] l in DispatchQueue.main.async { self?.batteryLevel = l } }
        if let d = UserDefaults.standard.data(forKey: Self.key),
           let p = try? JSONDecoder().decode([Profile].self, from: d) { profiles = p }
    }
    func persist() { if let d = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(d, forKey: Self.key) } }
    func sync() { connected = hp.isConnected; state = connected ? hp.state : nil }
    /// The chip stops advertising over BLE while the classic RFCOMM channel is open, so connect BLE (battery) first,
    /// then open RFCOMM. If BLE can't be reached within 6 s, go ahead without the battery.
    private func gate() {
        guard !rfcommAllowed, gateTimer == nil else { return }
        gateTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in self?.openGate() }
    }
    private func openGate() { gateTimer?.invalidate(); gateTimer = nil; rfcommAllowed = true; hp.refresh(); sync() }
    func refresh() {
        if !rfcommAllowed { battery.request(); gate(); return }
        hp.refresh(); sync()
        if batteryLevel == nil || Date().timeIntervalSince(lastBattery) > 120 { lastBattery = Date(); battery.request() }   // retry until we have a level, then at most every 2 min
    }

    func setEQ(_ c: UInt8) { state?.eq = c; hp.setEQ(c) }
    func setANC(_ r: UInt8) { state?.anc = r; hp.setANC(r) }
    func toggle(_ i: Int) {
        guard let s = state else { return }
        let f = features[i]; let new = !s[keyPath: f.key]
        state?[keyPath: f.key] = new
        if f.cmd == 11 && new { state?.game = false; state?.dual = false }
        hp.setToggle(f.cmd, new)
    }
    func apply(_ p: Profile) { state?.eq = p.eq; state?.anc = p.anc; hp.apply(p) }
    func saveProfile(_ name: String) {
        guard let s = state, !name.isEmpty else { return }
        profiles.removeAll { $0.name == name }
        profiles.append(Profile(name: name, eq: s.eq, anc: ancRawForCurrent(s.anc)))
        persist()
    }
    func delete(_ p: Profile) { profiles.removeAll { $0.name == p.name }; persist() }
}

// MARK: - Views

struct Tile: View {
    let title: String; let icon: String; let selected: Bool
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 18, weight: .medium))
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor : Color.primary.opacity(0.08)))
            .foregroundColor(selected ? .white : .primary)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary) }
}

struct ContentView: View {
    @ObservedObject var model: Model
    @State private var naming = false
    @State private var newName = ""

    let eqCols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    let ancCols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
    let featCols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    let profCols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)

    var on: Bool { model.connected && model.state != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            SectionTitle(text: "Sound")
            LazyVGrid(columns: eqCols, spacing: 8) {
                ForEach(eqPresets, id: \.code) { p in
                    Tile(title: p.name, icon: symbols[p.name] ?? "music.note",
                         selected: model.state?.eq == p.code, enabled: on) { model.setEQ(p.code) }
                }
            }
            SectionTitle(text: "Noise control")
            LazyVGrid(columns: ancCols, spacing: 8) {
                ForEach(ancModes, id: \.raw) { a in
                    Tile(title: a.name, icon: symbols[a.name] ?? "ear",
                         selected: model.state.map { ancName($0.anc) == a.name } ?? false, enabled: on) { model.setANC(a.raw) }
                }
            }
            SectionTitle(text: "Features")
            LazyVGrid(columns: featCols, spacing: 8) {
                ForEach(Array(model.features.enumerated()), id: \.offset) { i, f in
                    let isOn = model.state?[keyPath: f.key] ?? false
                    let blocked = (model.state?.hq ?? false) && (f.cmd == 8 || f.cmd == 6)
                    Tile(title: f.title, icon: f.icon, selected: isOn, enabled: on && !blocked) { model.toggle(i) }
                }
            }
            SectionTitle(text: "Profiles")
            LazyVGrid(columns: profCols, spacing: 8) {
                ForEach(model.profiles, id: \.name) { p in
                    let sel = model.state.map { $0.eq == p.eq && ancName($0.anc) == ancName(p.anc) } ?? false
                    Button { model.apply(p) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) { Image(systemName: "bookmark.fill").font(.system(size: 11)); Text(p.name).font(.system(size: 12, weight: .semibold)).lineLimit(1) }
                            Text("\(eqLabel(p.eq)) · \(ancName(p.anc))").font(.system(size: 10)).opacity(0.8).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(sel ? Color.accentColor : Color.primary.opacity(0.08)))
                        .foregroundColor(sel ? .white : .primary)
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain).opacity(on ? 1 : 0.35).disabled(!on)
                    .contextMenu { Button("Delete “\(p.name)”", role: .destructive) { model.delete(p) } }
                }
                if !naming {
                    Button { newName = ""; naming = true } label: {
                        HStack(spacing: 5) { Image(systemName: "plus.circle"); Text("Save current…").font(.system(size: 12, weight: .medium)) }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4])))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain).opacity(on ? 1 : 0.35).disabled(!on)
                }
            }
            if naming {
                HStack {
                    TextField("Profile name", text: $newName).textFieldStyle(.roundedBorder).onSubmit(commit)
                    Button("Save", action: commit).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { naming = false }
                }
            }
            if !model.profiles.isEmpty { Text("Right-click a profile to delete it").font(.system(size: 10)).foregroundColor(.secondary) }
            Divider()
            HStack {
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.buttonStyle(.plain)
                Spacer()
                Button { NSApp.terminate(nil) } label: { Label("Quit", systemImage: "power") }.buttonStyle(.plain)
            }.font(.system(size: 11)).foregroundColor(.secondary)
        }
        .padding(14)
        .frame(width: 400)
    }

    func commit() {
        model.saveProfile(newName.trimmingCharacters(in: .whitespaces)); naming = false
    }

    var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.connected ? "headphones" : "headphones.slash").font(.system(size: 22))
            VStack(alignment: .leading, spacing: 1) {
                Text("HiTune Max5c").font(.system(size: 14, weight: .semibold))
                Text(model.connected ? "Connected" : "Not connected — pair over Bluetooth")
                    .font(.system(size: 11)).foregroundColor(model.connected ? .green : .secondary)
            }
            Spacer()
            if let s = model.state {
                if let b = model.batteryLevel { HStack(spacing: 4) { Image(systemName: batterySymbol(b)); Text("\(b)%").font(.system(size: 12, weight: .medium)) } }
            }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.image = sym("slider.vertical.3")
        item.button?.target = self
        item.button?.action = #selector(toggle)
        let host = NSHostingController(rootView: ContentView(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        model.refresh(); updateIcon()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self, !self.popover.isShown else { return }
            self.model.refresh(); self.updateIcon()
        }
    }

    @objc func toggle() {
        if popover.isShown { popover.performClose(nil); return }
        guard let b = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        DispatchQueue.main.async { self.model.refresh(); self.updateIcon() }
    }

    func updateIcon() {
        item.button?.appearsDisabled = !model.connected
        item.button?.toolTip = model.connected ? "HiTune Max5c · Connected" : "HiTune Max5c · Not connected"
    }
}

if CommandLine.arguments.contains("--batterytest") {   // headless: run the app's real startup path and print what the battery reader gets
    let m = Model(); let t0 = Date()
    func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
    for t in [0.2, 5, 10, 15, 20, 25] { RunLoop.main.add(Timer(timeInterval: t, repeats: false) { _ in
        m.refresh(); print("[\(ms()) ms] refresh -> battery=\(m.batteryLevel.map(String.init) ?? "nil") connected=\(m.connected) eq=\(m.state.map { eqLabel($0.eq) } ?? "nil")") }, forMode: .common) }
    RunLoop.main.run(until: Date().addingTimeInterval(32)); exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    let hp = Headphones()
    let t0 = Date()
    func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
    var original: UInt8?
    hp.onChange = { print("  [\(ms()) ms] state eq=\(hp.state.map { eqLabel($0.eq) } ?? "nil")") }
    hp.refresh()
    func at(_ s: Double, _ f: @escaping () -> Void) { RunLoop.main.add(Timer(timeInterval: s, repeats: false) { _ in f() }, forMode: .common) }
    at(1.0) { original = hp.state?.eq; print("[\(ms()) ms] click Pop"); hp.setEQ(3) }
    at(1.05) { print("[\(ms()) ms] click Noise Off immediately after"); hp.setANC(0xD0) }
    at(1.1) { print("[\(ms()) ms] click Jazz immediately after"); hp.setEQ(1) }
    at(3.0) { print("[\(ms()) ms] FINAL eq=\(hp.state.map { eqLabel($0.eq) } ?? "nil") (expected Jazz)"); if let o = original { hp.setEQ(o) } }
    at(4.0) { print("[\(ms()) ms] restored eq=\(hp.state.map { eqLabel($0.eq) } ?? "nil")"); exit(0) }
    RunLoop.main.run(until: Date().addingTimeInterval(8))
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
