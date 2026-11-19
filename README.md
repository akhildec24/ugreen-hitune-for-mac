# UgreenEQ

A small macOS menu bar app that controls **UGREEN HiTune Max5c** headphones over Bluetooth: sound profile
(EQ preset), noise control, a few feature toggles, and saved profiles. UGREEN only ships a phone app for
these settings, so on a Mac the headphones are stuck on whatever they were last set to — for us, a
bass-heavy default with no way to change it.

This repository holds the app, the small research tools used to work out how the headphones talk, and a
write-up of everything that was tried, including what did **not** work.

![status](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey) <!-- tested on macOS 27.2, Apple silicon -->

## What it does

Click the menu bar icon to open a tile panel:

| Section | What you get |
|---|---|
| **Sound** | The headphones' 8 built-in EQ presets: Classic, Jazz, Electronic, Pop, Classical, Rock, Bass, Treble |
| **Noise control** | Off, Light, Medium, Deep, Adaptive, Transparency |
| **Features** | Spatial audio, Game mode, Dual connect, Hi-Q decoding |
| **Profiles** | Save "preset + noise mode" combos by name; right-click to delete |
| **Header** | Connection state and battery level |

Everything is applied **on the headphones themselves**. The app does not process or re-route Mac audio, so
your Mac's own output stays flat for reference and works the same with any other output device.

## Requirements

- macOS 13 or later (developed and tested on macOS 27.2, Apple silicon)
- Xcode command-line tools (`swiftc`, `iconutil`, `codesign`)
- UGREEN HiTune Max5c paired and **connected over Bluetooth** (the controls do not work over the USB cable)

## Build and install

```sh
cd UgreenEQ
./build.sh              # builds UgreenEQ.app (generates the icon on first run)
./build.sh --install    # also copies it to /Applications and launches it
```

- The app is signed **ad-hoc** (`codesign --sign -`). macOS asks for Bluetooth permission the first time,
  and can ask again after a rebuild because the ad-hoc signature changes.
- It is not notarised. See [Signing notes](#signing-notes).
- A headless self-test of the command queue is built in:
  `UgreenEQ.app/Contents/MacOS/UgreenEQ --selftest` from the `UgreenEQ` folder (changes the EQ preset briefly, then restores it). `--batterytest` runs the startup path headless and prints the battery level it reads.

## How it works

Two layers (all in `main.swift`):

- **`Headphones`** — talks to the headphones' serial service (`JL_SPP`, RFCOMM channel 1) using UGREEN's own
  packet protocol (`AA BB CC <cmd> <len> <data> <crc16>`). It keeps the channel open and sends commands
  through a **non-blocking queue**: one packet in flight at a time, replies matched to the packet that was
  sent, one quick retry on a missed reply, reconnect on failure.
- **`BatteryReader`** — reads the real battery level from the chip's Jieli RCSP service over **BLE**
  (`AE00`/`AE01`/`AE02`, GetSystemInfo attribute 0). Read-only, no pairing. It connects **before** the
  classic channel opens, because the chip stops advertising over BLE while the classic channel is in use.
  If the level cannot be read, the app hides the battery instead of showing a wrong number.
- **`Model` + SwiftUI views** — an `ObservableObject` the panel binds to. Clicks update the tile
  immediately (optimistic update) and the real state from the headphones' reply overwrites it.

The window is an `NSPopover` hosting the SwiftUI panel, opened from an `NSStatusItem`.

Protocol details are in [UgreenEQ/docs/INVESTIGATION.md](UgreenEQ/docs/INVESTIGATION.md).

## Repository layout

```
README.md
.gitignore
UgreenEQ/
  main.swift         the whole app (protocol, queue, model, SwiftUI, app delegate)
  Info.plist         bundle metadata (menu-bar-only app, Bluetooth usage string)
  build.sh           build, ad-hoc sign, optional --install
  make-icon.swift    generates the dot-matrix app icon (AppIcon.icns) with plain AppKit drawing
  tools/             small research tools (see below)
  docs/INVESTIGATION.md   what we tried, what worked, protocol reference
```

Research tools in `UgreenEQ/tools/` (each is a single file; compile with `swiftc -O file.swift -o name`).
The serial channel can only be opened by one program at a time, so **quit UgreenEQ before using `ugreen-cli`**:

| Tool | Purpose |
|---|---|
| `ugreen-cli.swift` | Command-line client for the UGREEN protocol; read the state or set an EQ preset |
| `rcsp-probe.swift` | Read-only probe of Jieli's standard RCSP service over BLE (found that custom EQ is *not* exposed) |
| `usb-formats.swift` | Lists the PCM formats the headphones offer over USB or Bluetooth |
| `usb-set-96k.swift` | Sets the USB output to 96 kHz / 24-bit |

## What we achieved

- Found a working way to control the headphones from a Mac **without a phone**: UGREEN's serial protocol over
  Bluetooth, reimplemented and verified against the real device (state read-back after each change).
- Built a polished menu bar app around it, including saved profiles and an icon.
- Fixed a real race condition (see [Performance and the race condition](#performance-and-the-race-condition)).
- Established what is **not** possible, so nobody has to repeat the dead ends (custom EQ bands, firmware
  changes over USB-C, LDAC on macOS).
- Confirmed the **USB-C hi-res path**: 96 kHz / 24-bit stereo works over the cable.

## Known limitations

- **Only the 8 fixed presets.** The firmware does not expose custom EQ bands (checked over Jieli's RCSP, the
  protocol UGREEN's own app is built on). The headphones' tuning cannot be edited from the Mac.
- **Bluetooth only.** Over USB-C the headphones expose audio and media keys only; there is no control
  interface.
- **No LDAC on a Mac.** The headphones support hi-res over Bluetooth with LDAC (e.g. from Android). To our
  knowledge macOS offers only SBC and AAC, so over Bluetooth the Mac cannot reach that quality. Use the
  USB-C cable for 96 kHz / 24-bit. (We did not verify codec support on macOS 27.)
- **Battery level comes from RCSP, not the usual places.** On this firmware the UGREEN protocol's battery byte
  and the level macOS shows (via the hands-free link) were both stuck at 100% for days, while the RCSP value
  fell steadily (92% → 91% → 90% over several hours of use). The absolute accuracy of the RCSP number has not
  been checked against a second trusted source, and the charging flag (probably bit 7) is not shown. If the
  BLE link cannot be made (for example the headphones are not advertising), no battery is shown.
- **Feature toggles are lightly verified.** Sound presets and noise control were checked against the real
  headphones. Spatial audio, Game mode, Dual connect and Hi-Q decoding use command numbers taken from
  Gadgetbridge's implementation and have not been individually confirmed on this unit.
- The app finds the headphones by name (`HiTune`) and uses RFCOMM channel 1; other UGREEN models may differ.
- Whether the chosen preset survives powering the headphones off and on was not tested.
- The "factory reset" command exists in the protocol and is **intentionally not implemented**.

## Performance and the race condition

The first versions opened and closed the Bluetooth channel for every command and waited for the reply in a
nested run loop on the main thread. Two problems followed:

1. **Latency spikes.** The headphones sometimes ignored the first request after a reopen, so the app waited
   out its whole 1.5 s timeout (measured: 1,513 ms vs a normal ~120 ms).
2. **A race.** While the app waited inside that nested loop, other queued UI actions could run inside it, and a
   "busy" flag silently dropped them. A click could be lost or applied late — the symptom was pressing *Pop*,
   nothing happening, and Pop being applied when the next button was pressed.

Fix: keep the channel open and drive it with an asynchronous command queue (no blocking waits, ordered,
reply-matched). Measured afterwards: refresh 14–31 ms, preset change 46–87 ms, and three clicks 50 ms apart
all applied in order.

## Signing notes

- Builds are ad-hoc signed. One build signed with an Apple Development certificate was flagged by macOS
  malware protection ("Malware Blocked and Moved to Bin") and removed. We could not find the reason in the
  system logs, did not try to bypass the block, and went back to ad-hoc signing, which has run without
  warnings since. The code makes no network connections; it only talks to the paired headphones and stores
  saved profiles in the app's preferences.
- No notarisation, no hardened runtime, not distributed anywhere.

## Credits and references

- [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) — its UGREEN HiTune Max 5c support
  documents the serial protocol (command numbers, preset and noise-control codes, CRC). This project is an
  independent reimplementation of those facts in Swift; no Gadgetbridge code is included.
- [kagaimiq/jielie](https://github.com/kagaimiq/jielie) and
  [jl-uboot-tool](https://github.com/kagaimiq/jl-uboot-tool) — reverse-engineering notes on Jieli chips
  (used to understand the firmware options; nothing from them is used at runtime).
- [Jieli iOS SDK](https://gitee.com/Jieli-Tech/iOS-JL_Bluetooth) — public headers documenting the RCSP
  protocol used in the probe.

## License

No license has been chosen yet.
