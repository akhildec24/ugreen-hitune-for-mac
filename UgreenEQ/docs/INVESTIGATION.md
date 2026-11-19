# Investigation notes — UGREEN HiTune Max5c on a Mac

How the headphones were examined, what was found, and what turned out to be impossible. Written so that
nobody has to repeat the dead ends. All observations are from one unit on macOS 27.2 (Apple silicon) unless
stated otherwise. Items marked **(unverified)** come from documentation or other people's work, not from a
test on this unit.

## 1. The problem

- The headphones (a ~£22 hybrid-ANC Bluetooth model) sound very bass-heavy by default.
- UGREEN offers EQ presets, noise-control modes and a few features only through a phone app. There is no Mac
  app, and macOS has no system equaliser.
- Questions we set out to answer:
  1. Can the headphones' sound profile be changed from the Mac (over USB-C or Bluetooth)?
  2. Can the firmware be inspected or modified?
  3. Is custom EQ (own band gains) possible on the device itself?
  4. Can the Mac get the "high-resolution" audio the headphones are capable of?

Constraint from the user: **no Mac-side audio processing** — the Mac's output must stay flat; the change has
to happen on the headphones.

## 2. Summary of findings

| Question | Answer |
|---|---|
| Control over USB-C? | **No.** USB exposes audio and media keys only. |
| Control over Bluetooth? | **Yes**, through UGREEN's serial protocol (RFCOMM channel 1). Sound presets and noise control confirmed with read-back. |
| Custom EQ bands on the device? | **No.** Only the 8 fixed presets. The standard Jieli service does not expose EQ attributes on this firmware. |
| Firmware dump / modification? | **Not attempted.** Needs extra hardware and a tool that does not run on macOS; see §6. |
| Hi-res audio on the Mac? | **USB-C: yes, 96 kHz / 24-bit.** Bluetooth: no LDAC on macOS (to our knowledge). |

## 3. The hardware

Identified from `ioreg`, `system_profiler`, CoreAudio and the Bluetooth stack:

- **Chip:** Jieli (Zhuhai Jieli Technology). The BLE service reports the SDK name `jl_sdk_ac697_publish`,
  i.e. the **AC697 family**.
- **USB:** "USB Composite Device", vendor `0x3654` (Jieli), product `0x4A55`, USB 1.10 **full speed
  (12 Mbit/s)**. Interfaces: audio control, two audio streaming interfaces, and one HID interface.
- **HID interface:** standard Consumer Control (usage page `0x0C`), 2-byte input reports, no output or feature
  reports → play/pause/volume keys only. **No vendor-defined interface**, so no hidden settings channel.
- **Bluetooth (classic):** vendor `0x05D6`, product `0x000A`, class of device `0x240404`, firmware
  "2.4.0" as reported to macOS. SDP lists `JL_A2DP`, `JL_HFP`, `JL_HID` and **`JL_SPP` on RFCOMM channel 1**.
- **Bluetooth LE:** advertises while connected; GATT service `AE00` with characteristics `AE01` (write without
  response) and `AE02` (notify) — Jieli's standard RCSP control service. Three more custom services exist
  (`E6781EC0-…`, `6666…`, `8686…`); they were listed but not explored.

### USB audio formats

| Direction | Formats |
|---|---|
| Output | 44.1 / 48 / 96 kHz, each at 16-bit and 24-bit, stereo |
| Input (microphone) | 48 kHz, 16-bit, mono |

macOS defaulted to 48 kHz. Setting the stream's physical format to 96 kHz / 24-bit worked and the device's
nominal rate reported 96,000 Hz afterwards. (The headphones list the stream twice; the second copy is
inactive, which briefly looked like a failed switch.) USB 1.1 has the bandwidth for this (≈4.6 Mbit/s). We did
**not** verify whether the headphones' DAC runs natively at 96 kHz or converts internally.

Over Bluetooth, macOS sees an A2DP output at 44.1 kHz stereo and an HFP stream at 16 kHz mono. These are the
Mac-side PCM formats, not the Bluetooth codec.

### Does USB change the sound?

No. The bass-heavy profile was identical over the cable, so the tuning is applied in the headphones' DSP
regardless of the connection. (Third-party reports suggest USB may even need *more* bass reduction than
wireless — unverified.)

## 4. The UGREEN serial protocol (what the app uses)

Carried over RFCOMM channel 1. Documented by Gadgetbridge's UGREEN HiTune Max 5c support; **reimplemented and
checked against the real headphones** (state read-back after every set command).

### Framing

```
request : AA BB CC  <cmd>  <len>  <data…>  <crc16 little-endian>
response: DD EE FF  <cmd>  <status>  <len>  <payload…>  <crc16 little-endian>
```

CRC-16 with initial value `0xFFFF` and polynomial `0xA001` (reflected, i.e. CRC-16/MODBUS), computed over
`cmd, len, data` (requests) or `cmd, status, len, payload` (responses). Unsolicited notifications use the
header `85 86 87`; the app ignores them.

### Commands

| cmd | Meaning | Payload | Verified here |
|---|---|---|---|
| 1 | Version | `00` | no |
| 4 | **Device state** | `00` | **yes** |
| 5 | **EQ preset** | preset code | **yes** |
| 9 | **Noise control** | mode byte | **yes** (via the app and self-test) |
| 6 | Dual connection | `00`/`01` | no (from Gadgetbridge) |
| 8 | Game mode | `00`/`01` | no |
| 11 | High-quality decoding | `00`/`01` | no |
| 18 | Spatial audio | `00`/`01` | no |
| 12 | Prompt language | code | not implemented |
| 17 | Prompt volume | 1–15 | not implemented |
| 19 | Wear detection | `00`/`01` | not implemented |
| 14 | **Factory reset** | `00` | **deliberately not implemented** |

### Example exchanges (from the real device)

```
get state    →  aa bb cc 04 01 00 31 91
             ←  dd ee ff 04 01 16 64 ff ff a0 00 00 00 00 08 00 00 07 00 00 00 00 00 00 00 09 00 00 96 d9
set Jazz     →  aa bb cc 05 01 01 a1 91
             ←  dd ee ff 05 01 01 01 a5 2c
```

### Device-state payload (cmd 4, 22 bytes)

| Offset | Meaning |
|---|---|
| 0 | Battery % — **unreliable: stuck at 100 on this firmware** (see section 4a) |
| 1–2 | `FF FF` (not understood) |
| 3 | Noise-control byte (see below) |
| 4 | EQ preset code |
| 5 / 6 / 7 | Dual connect / Game mode / Hi-Q decoding (`01` = on) |
| 16 | Prompt language |
| 19 | Prompt volume |
| 20 | Spatial audio |

### Codes

- **EQ presets:** Classic `0`, Jazz `1`, Electronic `2`, Pop `3`, Classical `4`, Rock `5`, Bass `6`, Treble `7`.
  Classic was the default after pairing in our tests. The presets were chosen by ear; no frequency response was
  measured.
- **Noise control:** Off `D0`, Light `C1`, Medium `B1`, Deep `A1`, Adaptive `D1`, Transparency `D2`. "Off" can
  read back as `A0`/`B0`/`C0`/`D0`, depending on the last active depth; the app treats all of them as Off.

### Codec report (cmd 15) and verified toggle

- Cmd 15, data `00` -> payload pairs `(slot, codec)`; slot 1 and 2 are the two dual-connect devices; codec `0` SBC,
  `2` AAC, `255` LDAC (read-only; verified here: `01 02`).
- Cmd 13 is sent by the headphones unsolicited after some commands: `01 01 <device name> <6-byte address>` (info about
  the connected device in slot 1).
- Cmd 11 (Hi-Res audio decoding on/off) is now **verified on this unit** (see section 7). The other toggles (6, 8,
  18, 19) match the command numbers in UGREEN's own Android app but are still not individually tested here.

## 4a. Battery level: what is reported where

| Source | What it said |
|---|---|
| macOS (System Information, menu bar), via the hands-free link | 100%, unchanged for days |
| UGREEN protocol, cmd 4 payload byte 0 | `0x64` = 100, identical on repeated reads |
| Jieli RCSP over BLE, GetSystemInfo (func `FF`, mask bit 0), attribute type 0 | `0x5C` = 92, later 91, then `0x5A` = 90 |

Request: `FE DC BA C0 07 <len BE16> <sn> FF 00 00 00 01 EF`. Reply: `FE DC BA 00 07 <len> 00 <sn> FF 02 00 <pct> EF`
(attribute list entries are `len, type, data`; type 0 is the battery). Bit 7 of the value is probably a
charging flag (not verified).

How other devices report battery to a Mac: Apple's documented route is the hands-free vendor commands
`AT+XAPL` / `AT+IPHONEACCEV`; HFP 1.7 also has an optional battery HF indicator, some vendors use their own
commands, and BLE has the standard Battery Service (0x180F). This chip does not expose a Battery Service, and
macOS shows 100%, so the RCSP value is the only one that moved. We did not capture the hands-free traffic to
see exactly what the headphones send.

**Ordering constraint.** While the classic RFCOMM channel is open, the chip does not advertise over BLE
(scan with the app quit: headphones seen; with the app running: not seen). The app therefore connects
BLE first (6 s limit), then opens RFCOMM. Whether both links stay up together was observed working in the app,
but is not otherwise characterised. The BLE identifier is cached so later launches can connect directly.

## 5. Custom EQ over Jieli's standard service — ruled out

Jieli's public iOS SDK documents a "set system EQ" command that takes a mode and a custom array of band
values, so we probed whether this firmware supports it (`tools/rcsp-probe.swift`, **read-only**):

- **Frame format** (standard RCSP): `FE DC BA <flag> <cmd> <len BE16> <payload> EF`; flag `C0` = command
  needing a reply; the payload starts with a one-byte sequence number.
- **Authentication is not required** for these queries on this unit. `GetTargetInfo` (`cmd 0x03`, mask
  `FFFFFFFF`) works unauthenticated and returns TLV attributes including the Bluetooth address and the SDK
  name `jl_sdk_ac697_publish`. (We also tried Jieli's official pairing handshake from the SDK's macOS
  `JL_HashPair` library; the headphones did not answer it, and it turned out to be unnecessary.)
- **`GetSystemInfo`** (`cmd 0x07`, function `FF`): the SDK's `cmdGetSystemEQ` was found by disassembling the
  compiled iOS library to use mask `0x1010` (attributes 4 and 12). With mask `FFFFFFFF` the headphones return
  attributes `0, 2, 6, 9, 10, 13, 14, 15, 27` — **no attribute 4 or 12**. Asking for those two explicitly
  returns an empty list.

Conclusion: the firmware does not expose EQ through the standard service. This matches UGREEN's own app, which
offers only fixed presets, and reviews saying custom EQ is unavailable. The 8 presets are the limit.

## 6. Firmware: why we did not go further

Researched, **not attempted**; nothing was ever written to the headphones' flash.

- The chip family is documented by community notes ([kagaimiq/jielie](https://github.com/kagaimiq/jielie)).
  A flash read/write tool exists ([jl-uboot-tool](https://github.com/kagaimiq/jl-uboot-tool)) with the AC697
  family listed as "seems to work".
- Entering the chip's USB download mode needs a special **`USB_KEY` bit pattern (`0x16EF`) on the USB D+/D-
  lines at power-up**. A normal host port cannot send it. Jieli sells a dongle; open-source RP2040 / ESP32
  implementations exist for other Jieli devices (MvaveFM1Unbricker, fm1-esp32-unbrick).
- The tool uses Linux/Windows SCSI pass-through and does not run on macOS.
- The headphones have a battery, so unplugging may not reset the chip; a clean reset probably means opening
  them and disconnecting the battery.
- Newer Jieli SDKs can sign or encrypt firmware, and the EQ data format is undocumented. A dump might be
  unreadable, and a bad write could brick the unit.

Decision: not worth the risk for the likely outcome (the same bass cut the presets already provide).

## 7. Hi-res audio and LDAC

**Update.** The headphones **do offer LDAC over Bluetooth, and a Mac simply does not use it.** Evidence:

1. *Advertised A2DP endpoints (measured).* Asking the headphones for their stream endpoints (AVDTP DISCOVER +
   GET_CAPABILITIES, read-only, `UgreenEQ/tools/avdtp-probe.swift`) returned four sink endpoints:

   | SEID | Codec | Capability bytes |
   |---|---|---|
   | 1 | SBC | `00 00 ff ff 02 26` |
   | 2 | AAC (MPEG-2,4) | `00 02 80 01 8c 82 00 00` |
   | 3 | **Vendor-specific** | `00 ff 2d 01 00 00 aa 00 3c 07` = vendor `0x0000012D` (Sony), codec `0x00AA` (**LDAC**); sampling-frequency byte `3c` = 44.1 / 48 / 88.2 / 96 kHz |
   | 4 | SBC | `00 00 ff ff 02 26` |

2. *macOS's own log* shows the same four endpoints (`bluetoothd`, when the Mac starts the connection) and that
   macOS then picks **AAC at 44.1 kHz (about 127 kbps VBR)**. When the headphones start the connection, macOS logs only
   "2 available endpoints"; it ignores the vendor endpoint.
3. *UGREEN's protocol has a codec report:* command 15 (request data `00`) returns `(slot, codec)` pairs, one slot
   per connected device (dual connect). Codec values: `0` SBC, `2` AAC, `255` LDAC. Measured here: `01 02` (slot 1 =
   AAC), matching the Mac log.
4. UGREEN's product page claims Bluetooth 5.4, LDAC, and "96kHz/24-bit ... 990kbps" (the top LDAC mode).

**Hi-Q decoding does not gate LDAC.** Setting "Hi-Res audio decoding" (cmd 11) on or off did not change whether the
LDAC endpoint is advertised (the probe saw all four endpoints in both states; failed attempts were timing, not the
setting). The setting is verified to work: cmd 11 `01`/`00` flips state byte 7 and the headphones reply `01`. It is
exclusive with dual connect, audio sharing and the AI function in UGREEN's app.

**What this does not change.** macOS's Bluetooth service chooses between SBC and AAC and exposes no way for an app to
pick another codec. Getting LDAC from a Mac therefore needs software that speaks A2DP itself and feeds it audio through
a virtual output device (the approach of third-party tools such as Blue Bloom). That is a large, fragile project
(private macOS Bluetooth interfaces, a Core Audio plug-in running inside `coreaudiod`, forced takeover of the
headphones' audio link) and has not been attempted here. Without it, the practical hi-res route on a Mac is
**USB-C at 96 kHz / 24-bit** (§3). Not pursued: a USB Bluetooth transmitter with LDAC support; the SBC-bitpool tweak
for macOS, which helps SBC only.

**Method notes.** The AVDTP probe cannot normally open the signalling channel because macOS holds it; it disconnects the
headphones, reconnects them, and opens PSM 25 within about 100 ms. It succeeded in roughly half of the attempts, and
it briefly interrupts audio. The headphones also expose, over BLE, three custom services besides Jieli's `AE00`
(`E6781EC0-BCE6-11E5-8439-0002A5D5C51B`, `66666666-...`, `86868686-...`); we did not investigate them.

## 8. Approaches considered and not taken

- **Mac-side system EQ** (capture system audio with a Core Audio process tap, run it through an
  `AVAudioUnitEQ`, play to the headphones; or an existing app such as eqMac). Would allow fully custom
  curves, but adds latency, needs an audio-capture permission, can fail on DRM-protected streams, and — most
  importantly — was ruled out because the user wants the Mac's audio left flat.
- **Setting the preset once from a phone** and hoping it persists. Never tested; we had no suitable phone.

## 9. Method (chronological)

1. Read the product page and reviews; learned the app only offers fixed presets.
2. Enumerated the headphones over USB (`ioreg`, `system_profiler`, CoreAudio): composite audio device, no
   control interface; confirmed the sound is the same over the cable.
3. Looked at the chip (Jieli) and the firmware-update route; stopped at the hardware requirements.
4. Read the cached Bluetooth service list; found `JL_SPP` on RFCOMM channel 1 and the BLE `AE00` service.
5. Found Gadgetbridge's documented UGREEN protocol; wrote a small Swift client; verified reading and setting
   the EQ preset with read-back.
6. Probed Jieli's standard service read-only; found no EQ attributes.
7. Listed and set the USB audio format (96 kHz / 24-bit).
8. Built the menu bar app, then iterated on design (icons, tile layout, dot-matrix app icon).
9. Measured and fixed latency spikes and a race condition (see the main README).

## 10. Safety record

- Settings changed on the headphones during the work: EQ preset and noise-control mode only (the same
  things the phone app changes). Everything else was read-only.
- No firmware access or writes. No authentication or encryption was bypassed: the unauthenticated RCSP
  queries were answered by the device without any credentials.
- The factory-reset command was never sent.
