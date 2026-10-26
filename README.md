# MX Whoop

A native iOS (SwiftUI + CoreBluetooth) app that talks **directly** to a WHOOP MG / WHOOP 5.0 strap,
streams its raw data and analyses it on the phone. Includes a just-for-fun **Lie Detector**.

> Not affiliated with WHOOP. Use only with a strap you own. Not a medical device. The lie detector
> measures physiological arousal, not truth.

## Screens

| Tab | What it does |
|---|---|
| **Live** | Heart rate (5 min chart), beat-to-beat R-R tachogram, HRV (RMSSD, SDNN, pNN50), breathing rate from sinus arrhythmia, 100 Hz 3-axis motion, micro-tremor, experimental optical stream, live arousal gauge, CSV recording/export |
| **Lie Detector** | 60 s baseline → 3 truthful + 3 deliberate-lie calibration statements → ask anything → **TRUTH / LIE with a percentage**, per-signal breakdown, history, optional strap buzz on LIE |
| **Raw** | Every frame decoded and hex-dumped, packet counters, CRC failures, safe command console (hello, battery, buzz, live HR on/off, clock, wear status) |
| **Strap** | Connect / disconnect / demo mode, device info (MG vs 5.0, firmware, battery, worn), connection log |

**Demo mode** simulates a WHOOP MG (heartbeat with HRV, wrist tremor, pulse wave and lie reactions). Its
data is encoded into real WHOOP frames and goes through the same parser, so the whole app works in the
iOS Simulator.

## How it talks to the strap

Sources: [dofek protocol notes](https://github.com/Asherlc/dofek/blob/main/docs/whoop-ble-protocol.md),
[noop](https://github.com/ryanbr/noop) protocol docs, [whoop-rs](https://github.com/eugenehp/whoop-rs), and
the decompiled official Android app (v5.474.0). In that app, WHOOP MG is called **Maverick** and WHOOP 5.0 **Goose**.
Both use the same service.

```
Service  FD4B0001-CCE1-4033-93CE-002D5875F58A
  0002  write    command frames
  0003  notify   command responses      0004 notify  events
  0005  notify   data (HR, IMU, …)      0007 notify  Memfault
Standard 180D/2A37 heart rate (works unbonded), 180F battery, 180A device info

Frame:  AA 01 <len u16> 00 01 <CRC16-MODBUS of bytes 0-5>
        <type> <seq> <cmd> <params…, zero-padded to 4>   <CRC32 LE>
Hello:  AA 01 08 00 00 01 E6 71 23 01 91 01 36 3E 5C 8D
```

1. Find the strap. If iOS already has it connected (for example through the official WHOOP app on the same
   phone), the app reuses that bonded link. Otherwise it scans for FD4B0001.
2. Subscribe to the notify characteristics and write GET_HELLO **with response**. The command
   characteristic requires encryption, so the first time **iOS asks to pair**. Once the write succeeds,
   the link is bonded.
3. `TOGGLE_REALTIME_HR [01]` → packet 0x28 at ~1 Hz. Its fields are HR (offset 16), the R-R count (17),
   the R-R intervals in 1/1024 s ticks (18+2i) and the worn flag (26).
4. Raw IMU: `START_RAW_DATA [01]`, then `TOGGLE_IMU_MODE [01 01]` → 0x2B / layout 21 (1,244 bytes).
   Each record holds 100 samples of accel and gyro: ±8 g at 1/4096 g per LSB, and 2000 °/s full scale.

The app never offloads or acknowledges history. Acknowledging history lets the strap delete records the
official app has not synced yet. Firmware, pairing-reset, trim and reboot commands are never sent.

**If pairing is refused:** the strap is probably bonded to another phone. Tap the strap until the LED
flashes blue (pairing mode) and connect again. If iOS remembers a stale pairing, forget the strap in
Settings › Bluetooth.

## The lie detector

It uses a polygraph's Comparison Question approach, built from signals the strap actually has:

| Signal | Feature (response window 0.5–14 s vs the 10 s before) |
|---|---|
| Heart rate | peak rise, mean rise |
| R-R intervals | maximal beat acceleration (%), RMSSD drop (vagal withdrawal) |
| 100 Hz accelerometer | 4–12 Hz micro-tremor change, movement change |
| Optical (if the strap streams it) | pulse-amplitude drop (vasoconstriction) |

* **Baseline**: pseudo-questions are slid across 60 s of rest. This gives each feature's noise level, so
  everything is scored as a z-score.
* **Calibration**: your reactions to known truths and deliberate lies train a per-person diagonal
  discriminant. It is shrunk towards a prior because the sample is tiny, and tempered because the heart
  features are correlated.
* **Verdict**: a logistic probability, clamped to 3–97 %. If there are too few heart-rate samples you get
  "no signal". A lot of movement lowers confidence.

On simulated data with a realistic reaction size, the calibrated model gets about 80–87 % of questions
right. Real people are noisier. Anxiety, embarrassment or a hard question all look like a lie.

## Build

### Option A — GitHub Actions (no Mac needed)
Every push to `main` builds `MXWhoop-unsigned.ipa`. Download it from the run's **Artifacts**. Tags `v*`
also attach it to a Release. Sideload and sign it with your own Apple ID using
[AltStore](https://altstore.io), [SideStore](https://sidestore.io) or [Sideloadly](https://sideloadly.io).
Free Apple IDs need re-signing every 7 days.

### Option B — Xcode on a Mac
```sh
brew install xcodegen
xcodegen generate
open MXWhoop.xcodeproj      # pick your team under Signing & Capabilities, run on an iPhone
```
Bluetooth does not work in the Simulator, so use Demo mode there.

### Tests
```sh
cd Packages/WhoopKit && swift test
```
The tests pin framing against captured frames (the client hello, and the official app's IMU toggle from a
PacketLogger capture). They also round-trip every decoder and check that the lie detector separates
simulated truths from lies.

## Layout

```
Packages/WhoopKit        platform-neutral core (no CoreBluetooth): framing, CRCs, reassembly,
                         parsers, HRV / breathing / tremor analytics, lie-detector model, simulator
MXWhoop/BLE              CoreBluetooth client + demo strap
MXWhoop/Model            SensorHub (live state), Recorder (CSV), LieDetectorSession (state machine)
MXWhoop/Views            SwiftUI screens and Swift Charts
project.yml              XcodeGen spec
```

## Credits

Protocol knowledge comes from community reverse-engineering. dofek (Asherlc), noop (PolyForm
Noncommercial, used here as documentation only) and whoop-rs (Apache-2.0) were all invaluable. All code in
this repository is original.
