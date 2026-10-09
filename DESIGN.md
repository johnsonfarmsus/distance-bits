# Light-Comm: Phone-to-Phone Text Over Light

---

## 1. Overview

Two phones, airplane mode ON, no pairing, no WiFi, no Bluetooth. One phone's screen
strobes a flashing color grid; the other phone's rear camera reads it and displays a
received text message. Errors are handled by fountain coding — there is no
"retransmit," only "keep listening until enough chunks arrive." A trickle-rate uplink
(flashlight pulses from receiver to the sender's selfie camera) reports lock, trouble,
and DONE.

This is a two-party link: one sender, one receiver. Everything below assumes exactly
one phone on each end.

The stack is designed so that **every failure mode is visible, measurable, and
loggable.** Range is a first-class knob: the user picks an approximate distance and
the transmitter trades bitrate for cell size accordingly, so the same app scales from
a hallway to the far side of a field.

One rule runs through the whole design: **light carries data, dark carries the clock.**
Every payload cell is always lit; the only dark thing on the screen is a single black
marker whose position (or presence) counts frames.

---

## 2. Motivation

Existing phone-light tools are either flashlight Morse apps (slow, manual, no error
correction) or high-bandwidth screen-to-camera systems like Cimbar and Decimen that
only work at arm's length. Nothing sits in the middle: an automated, error-corrected
text link that degrades gracefully from a few meters out to tens of meters.

Things this project exists to find out:

- What the real BER-vs-distance curve looks like for a phone screen read by a phone camera
- How far a 1-cell "blob" link can be pushed before it becomes worse than Morse
- Whether blue survives as a fourth payload color at range, or whether three colors
  is the practical ceiling
- Whether a fountain code plus a one-bit-per-second uplink is enough protocol for a
  usable two-way experience
- What breaks in the browser-only version versus native

---

## 3. Link Architecture (Asymmetric)

```
        FORWARD LINK (fat)                       RETURN LINK (skinny)
   Sender screen ──grid strobe──►         Receiver flash ──pulses──►
   (~7–420 bit/s, range-dependent)    ◄──(~1 bit/s LOCK/TROUBLE/DONE)────
   ┌──────────────┐                        ┌──────────────┐
   │ SENDER PHONE │   rear cam of RX       │ RECEIVER PHONE│
   │  screen: TX  │                        │  rear cam: RX │
   │  front cam:  │◄──── ACK watch ────────│  flash: TX    │
   │    listener  │  flash faces sender    │  screen: RX UI│
   └──────────────┘                        └──────────────┘
```

Geometry is cross-mirrored: the sender's screen and selfie camera are on the same
face, so aiming the screen at the receiver simultaneously aims the listening camera.
The receiver's rear camera and flash are on the same face, so aiming the camera at
the sender aims the flash. The sender's own screen faces away from them, so the
sender gets status by **haptics**: one long buzz = delivered ✓; a single tick =
receiver locked on; three shorts = receiver reporting trouble.

---

## 4. Frame Rates

Starting point: **transmitter 30 fps, receiver 60 fps.** The receiver captures two
frames per transmitted frame, so it always has at least one capture that does not
straddle a screen transition. A transmitted frame is accepted only when two
consecutive captures decode identically (or, at 15 fps TX / 60 fps RX, when three of
four agree). The marker moving between frames is what tells the receiver a new
frame has begun, even when the payload happens to repeat.

Step-down ladder if the accept rate is poor: TX 30→15→10 fps, RX stays at 60 if the
phone allows it, else 30. Frame rate is part of the range preset (§6) and can be
overridden in settings; it is not negotiated live.

Phone screens refresh at 60 or 120 Hz, so each transmitted frame is shown for at least
two refreshes. Mains-frequency flicker from venue LED/fluorescent lighting beats
against 30/60 fps capture; lock exposure where the platform allows it and expect
artifacts where it doesn't.

---

## 5. Modulation (Fixed Per Session, Configurable From the Start)

### 5.1 The marker

Every frame contains exactly one **black marker cell**. Payload cells are never black.
The marker is therefore always the darkest cell in the frame — trivial to find under
any white balance or exposure — and it does three jobs:

1. **Frame counter.** The marker walks a fixed path through the grid, one step per
   frame. Its position gives the frame index modulo the cell count.
2. **Orientation.** The walk order is known, so two consecutive frames tell the
   receiver which corner is which. The grid cannot be decoded upside down.
3. **Black reference.** Together with the brightest payload cell, it anchors relative
   color classification every frame, which matters on receivers that can't lock
   white balance (iOS web).

Because every payload cell is lit, the screen presents a stable, fully lit rectangle
with one dark hole. That outline against the dark bezel is the primary registration
feature; QR-style corner finders are **not** required and are kept only as an
optional setting for bright-background conditions.

### 5.2 Payload palettes

The codec is written generically over an alphabet of *k* lit colors. A frame's payload
cells are packed as a base-*k* number, so any palette size works without touching the
rest of the protocol. Three palettes ship from day one, and the choice is a
**settings toggle announced in the beacon** so both ends stay in sync:

| Mode | Payload palette | Colors (k) | Bits per 7-cell frame | Notes |
|------|-----------------|------------|----------------------|-------|
| 0    | W / R           | 2          | 7                    | mono-class decision on luminance (red ≈ 30% of white) and on the green channel (white has it, red doesn't); the long-range default |
| 1a   | R / G / W       | 3          | 11 (3⁷ = 2187 ≥ 2¹¹) | no blue, so no blue-vs-black boundary; the fallback if 1b misclassifies at range |
| 1b   | R / G / B / W   | 4          | 14                   | standard color-shift-keying set; blue is the weakest channel on cameras and can read as dark at range — the whole point of the toggle is to measure that |

**Blue on/off is a first-class switch**, present in the UI from the first build, not a
code change. Mode 1b with blue off *is* mode 1a; the codec just sees k=3 instead of 4.

Design rule: **shapes are cells in disguise.** A resolvable glyph alphabet spends the
same spatial-resolution budget as a finer grid, but color averages out under blur
while shape corners evaporate. Stripe and glyph experiments from earlier drafts are
parked; they would need their own marker treatment and are not on the critical path.

Color classification is always **relative**: each payload cell is classified against
the marker (black) and the running centroids of the lit colors seen in recent frames,
never against fixed RGB thresholds.

---

## 6. Range Presets and Grid Scaling

The user selects an approximate range on the sender. The preset sets the grid, the
frame rate, and the default palette; all three can be overridden in settings.

### 6.1 The pixel budget

Assume a receiver main camera with ~70° horizontal field of view and ~4000 px across.
Then the target is imaged at roughly **28.6 / d pixels per centimeter** (d in meters).
A 3× telephoto (~24° FOV) gives about **94 / d px/cm**, i.e. every distance below
scales by ~3.3× with a tele lens.

Usable screen area is about **6 × 12 cm** in portrait (finders off).

Decoding thresholds used below: **≥4 px across a cell's short side for a two-color
decision, ≥6 px for three or four colors.**

### 6.2 Why the ladder skips the 4-cell step

Shrinking 2×4 to 2×2 or 1×4 doesn't help much: the short side of each cell stays at
~3 cm, and blur mixes cells across their short side. The next step that actually buys
range is **1×2** (cells 6×6 cm) and then **1×1** (the whole screen is one cell, so
there is nothing to mix into and the receiver only needs to find a blob and read its
brightness/color).

### 6.3 Presets

| Preset | Range, main cam | Range, 3× tele | Grid | Cell size | Marker behavior | TX fps | Bits/frame (mode 0 / 1a / 1b) |
|--------|-----------------|----------------|------|-----------|-----------------|--------|-------------------------------|
| Near   | 0–12 m          | 0–40 m         | 2×4  | 3×3 cm    | black cell walks all 8 positions; 7 payload cells | 30 | 7 / 11 / 14 |
| Mid    | 12–25 m         | 40–80 m        | 1×2  | 6×6 cm    | black cell alternates between the two positions; 1 payload cell | 30, step to 15 | 1 / 1.58 / 2 |
| Far    | 25–50 m         | 80–150 m       | 1×1  | 6×12 cm   | frames alternate: colored symbol, then all-black separator | 15 | 0.5 / 0.79 / 1 |

Cell size at the far edge of each preset with the main camera: Near at 12 m ≈ 7 px
(color OK), Mid at 25 m ≈ 7 px (color OK), Far at 50 m ≈ 3.4 × 7 px blob (mode 0
default; 1a/1b are the experiment).

In Mid and Far the marker still gives the frame count (position alternation, or
separator frames) and a per-frame black reference; orientation is moot with one or
two cells.

### 6.4 What range costs

Time to deliver a 160-byte message (184 fountain chunks ≈ 1470 bits, plus ~12% epoch
header overhead ≈ 1650 bits on the wire), approximate:

| Preset / mode | 30 fps  | 15 fps  |
|---------------|---------|---------|
| Near, 1b      | ~4 s    | ~8 s    |
| Near, 1a      | ~5 s    | ~10 s   |
| Near, 0       | ~8 s    | ~16 s   |
| Mid, 1b       | ~28 s   | ~55 s   |
| Mid, 1a       | ~35 s   | ~70 s   |
| Mid, 0        | ~55 s   | ~110 s  |
| Far, 1b       | ~55 s   | ~110 s  |
| Far, 1a       | ~70 s   | ~140 s  |
| Far, 0        | ~110 s  | ~220 s  |

A 40-character message is a quarter of these. Far mode 0 at 15 fps is **7.5 bit/s,
Morse-class speed**; Far 1b at 30 fps is 30 bit/s, roughly 3× a good Morse operator.
Whether color holds up at 50 m decides which of those two the Far preset really is,
and that is one of the central measurements of the project.

---

## 7. Framing, Chunk Identification, and Fountain Code

### 7.1 The problem

A fountain code only works if the receiver knows which source bytes were XORed into
each coded chunk. That requires a chunk index. Frames carry 0.5 to 14 bits, so there
is no room for an explicit index in every chunk. Instead the index is **counted**,
with the marker as a sideband that makes counting robust and a periodic header that
resets it.

### 7.2 Definitions

- **Chunk** = one byte of fountain-coded payload. Always 8 bits, in every preset.
- **Chunk index c** = absolute count since message start. Chunk c's seed is
  `(messageID, c)`; the seed drives a PRNG that picks the degree (robust soliton
  distribution) and the set of source bytes XORed together.
- **Epoch** = 64 consecutive chunks (512 payload bits). A header is re-emitted at
  every epoch boundary.
- **Source bytes** = the message, length L (1–255 bytes), so L source blocks.
  Receiver needs roughly `L × 1.15` distinct chunks to peel it all.

### 7.3 Frame counting via the marker

- **Near (2×4):** marker position = frame index mod 8. At least the marker moves every
  frame, so boundaries are unambiguous, and up to 7 consecutive lost frames can be
  counted through. Longer gaps are resolved from capture timing (RX at 60 fps knows
  how many TX frames elapsed to within one).
- **Mid (1×2):** marker alternates sides = frame index mod 2; the capture clock
  resolves longer gaps.
- **Far (1×1):** symbol/separator alternation is self-clocking; a missing separator is
  a detected loss.

Payload bits within an epoch are treated as a **bitstream**: each frame contributes
7, 11, or 14 bits (Near) or its base-*k* symbol (Mid/Far), the receiver concatenates
them in frame order and chops the epoch into 64 byte-sized chunks. Chunk boundaries do
not need to align to frames. **If the frame count becomes ambiguous, discard the rest
of the epoch and wait for the next header** — the fountain code does not care which
chunks were lost.

### 7.4 Transmission sequence

1. **Beacon** — universal, always 1×1 symbol/separator, W/R, at the preset's frame
   rate: 8-bit sync word, 4-bit preset/grid code, 4-bit mode/fps code (includes the
   blue on/off bit). 16 bits ≈ 1 s at 30 fps, 2 s at 15 fps. Any receiver can decode it
   regardless of its settings, so the receiver auto-configures from the beacon.
2. **Header** — in the preset's native grid and palette, sent 3 times: message ID (8),
   length L (8), CRC-16 of plaintext (16), epoch number (8), header CRC-8 (8) = 48 bits.
3. **Flood** — 64 chunks, then back to step 1 with the incremented epoch number.
   Continues until the uplink says DONE or the sender cancels.

Overhead of beacon+header per epoch is ~64 bits against 512 payload bits, about 12%
in every preset. A receiver that starts late or loses lock waits at most one epoch
for a header.

### 7.5 Completion

Receiver peels the fountain code as chunks arrive, shows progress as
`decoded source bytes / L`, and on full decode checks CRC-16. CRC OK → DONE on the
uplink and the message is shown. CRC bad (rare — it means a chunk was misdecoded
rather than lost) → discard and keep listening.

---

## 8. Uplink Channel

Receiver faces the sender with **flash + rear camera**; the sender's **front camera
runs continuously** during transmission (no listening windows — the selfie camera
does not see its own screen, so glare is a fallback concern, not a design constraint;
if reflection off nearby surfaces proves to be a problem, cap screen brightness or
insert brief dark frames and log the effect).

Two-party link means the sender only ever watches for one light. The vocabulary is
deliberately tiny and timing-tolerant — no pulse counting:

| Receiver flash               | Meaning                | Sender reaction |
|------------------------------|------------------------|-----------------|
| off (default)                | receiving, keep going  | nothing |
| one 200 ms pulse every 2 s   | LOCKED on your signal  | single haptic tick on first lock |
| 1 Hz blink for ≥3 s          | TROUBLE — can't lock / bad decode rate | three short buzzes; user re-aims or picks a slower preset |
| steady ON for ≥3 s           | DONE, CRC OK           | halt at next chunk boundary, long buzz, show ✓ |

Sender-side detection: find the brightest compact blob in the front camera frame,
track its on/off over time, run a small state machine on hold durations. A phone LED
torch is a point source that reads easily at 50 m at dusk; in full daylight it is the
weakest part of the system — measure it.

Platform reality for the flash:

- Android Chrome: torch is controllable from a web page
  (`track.applyConstraints({advanced:[{torch:true}]})`, §13.7)
- iOS Safari/PWA: **torch is not controllable** (WebKit bug #243075, §13.8). A native
  app has full control (`AVCaptureDevice`). iOS web receivers run without an uplink:
  the receiver still decodes and displays, the sender just never gets a DONE and
  stops manually.
- Fallback for uplink-less receivers: **screen strobe** — receiver flips its screen
  between black and white at 1 Hz. This only works indoors in dim rooms where the
  screen's light bounces off surroundings visibly; in a lit hall a phone screen
  doesn't move ambient light enough for the sender's camera to notice. Treat as an
  experiment, not a feature.

---

## 9. UX and Configuration

Sender:
`TYPE → SET RANGE (+ optional overrides) → SEND (screen away, phone back toward self) → [tick: receiver locked] → HAPTIC ✓ → SHOW ✓ + checksum`

Receiver:
`OPEN RX → POINT → LOCKED (flash tick, progress % on own screen) → DONE + message shown`

Everything else is automatic: beacon decode and self-configuration, per-frame
alignment, frame counting, fountain decode, acknowledgment.

Settings available on the sender from the first build, all carried in the beacon so
the receiver follows without being told:

| Setting | Values | Default |
|---|---|---|
| Range preset | Near / Mid / Far | Near |
| Palette | mode 0 (W/R) / 1a (R/G/W) / 1b (R/G/B/W) — i.e. **blue on/off** plus mono | 1b for Near and Mid, 0 for Far |
| TX frame rate | 30 / 15 / 10 fps | per preset |
| Corner finders | off / on | off |
| Epoch length | 32 / 64 / 128 chunks | 64 |

Receiver-side settings (local only): lens choice (main / tele), exposure lock where
the platform allows it, and a debug overlay showing per-cell classification, marker
position, frame accept rate, and chunks decoded.

---

## 10. Software Distribution (No App Stores)

| Tier | Channel | Scope |
|---|---|---|
| Web | Static page on GitHub Pages; camera via `getUserMedia` over HTTPS; installable as a PWA for offline use | zero-install; full forward link; uplink on Android only |
| Native iOS | TestFlight public link (up to 10,000 testers; light beta review on the first build; builds expire after 90 days) | the uplink-complete version (torch) |
| Native Android | signed APK in the same repo, direct download | same features as iOS |

Caution: a single `.html` file opened via `file://` is usually denied camera access —
it has to be hosted (§13.7). PWA offline caching on iOS has sharp edges; rehearse the
first-load flow.

---

## 11. Hardware

- Sender: any phone (web or app). A laptop or TV as transmitter scales range roughly
  linearly with the width of the strobing area — a 30 cm-wide laptop screen moves every
  preset boundary out ~4×.
- Receiver: any phone with a rear camera. A 3× or 5× telephoto is the single biggest
  range multiplier (see §6.1). The iPhone 14 Pro-class 48 MP main sensor cropped vs
  the 12 MP 3× tele is worth an A/B test — similar per-pixel sampling at the same
  framing, main gathers more light.
- Stability: beyond the Near preset, lean the receiver on something or use a small
  tripod. Handheld shake is the hidden bitrate variable at range.
- Standalone hardware variant (future): ESP32-C3 + 0.42″ OLED as a grid-strobe node, or
  ESP32-S3 + KY-008 laser and photodiode pair as a fixed point-to-point link (~$8 per
  chain, §13.9).

---

## 12. Test Plan

Primary deliverable: a **BER-vs-distance curve per preset and palette**, plus the
uplink's daylight/dusk detection range.

1. Transmitter on a stand. Receiver at 5 / 10 / 15 / 25 / 40 / 50 m, main camera and
   tele, handheld and braced.
2. At each distance, run each preset that the table in §6.3 says should work, plus the
   next-finer one that it says should fail. Within each, run **blue on and blue off**
   back to back. Log accepted frames, misdecoded chunks (and which color pairs were
   confused), time-to-DONE, and lost-lock events over 100+ frames.
3. Record the environment: lighting type, sun angle, background behind the sender
   (dark wall vs bright sky — this is the finder-less registration test), autofocus
   behavior, exposure lock available or not.
4. Uplink: at each distance, does the sender detect LOCK/DONE in daylight, dusk, dark?
5. Repeat at 15 fps and 10 fps for any preset that fails at 30.

Predictions to be proven wrong (main camera, handheld):

- Near 1b exceeds 5% chunk error somewhere between 10 and 15 m; Near 1a holds ~2–3 m
  further; Near 0 holds to ~15 m
- Blue is the first color to fail everywhere, and it fails by being read as black
- Mid 0 holds to ~25 m
- Far 0 decodes at 50 m at 15 fps but not at 30 fps; Far 1b does not decode at 50 m
  on the main camera but does on the tele
- Screen-edge registration fails against a bright sky and finders have to come back on
- Screen-strobe uplink fails everywhere except a dim room

---

## 13. Risks / Open Questions

- Far preset in mode 0 is Morse-speed. A 160-char message is minutes, not seconds.
  State it in the UI before the user picks it.
- Frame counting between headers is the fragile part of the protocol. If losses
  cluster (autofocus hunt, handshake), whole epochs get discarded; if that happens
  often, shrink the epoch (the setting exists for this).
- Finder-less registration relies on the lit screen standing out from its background.
  Bright backgrounds are the failure case; finders are the fallback but cost payload
  area.
- Blue's viability is unknown at range; the toggle exists so this is a measurement, not
  a rewrite.
- W/R mode 0 is a slightly weaker decision than black/white would have been; if it
  underperforms at the far end of Far, a black/white payload with a non-black marker
  color is the escape hatch, at the cost of the "always lit" outline.
- The front-camera uplink detector has not been tested in daylight; a torch against a
  bright sky may be undetectable.
- Screen-strobe fallback uplink is unproven and likely fails in any lit space.
- Relative color classification is the only thing standing between iOS web receivers
  and auto-white-balance drift.
- TestFlight beta review is light but nonzero; submit the iOS build early.
- Venue LED/fluorescent lighting introduces mains-frequency artifacts at 30/60 fps
  capture and interacts with rolling shutter (§13.3).

---

## 14. Stretch Goals

- Beat the ~186 KB/s stationary / ~128 KB/s handheld QR-stream figures at arm's length
  (Decimen baselines, §13.2), then publish a coarse-grid long-range figure next to them
- Laptop/TV transmitter to a phone at 100+ m
- KY-008 + photodiode 10 m UART chain relaying the same protocol over a fixed laser
- ESP32-C3 grid-strobe nodes as non-phone transmitters
- Finer grids (3×5, 4×6) for the Near preset once the 2×4 curve is known, using the
  same walking-marker scheme

---

## 15. References & Prior Art

### 15.1 Cimbar — color-tile QR stream (closest ancestor)
- Repo: https://github.com/sz3/cimbar
- Design notes: https://github.com/sz3/cimbar/blob/master/ABOUT.md — bits-per-symbol vs
  cells-per-symbol dials; 4-color "mode 30" survives video pipelines where 64-color
  modes falter; fewer colors / fewer cells / 15–30 fps = more robust
- Discussion: https://news.ycombinator.com/item?id=25459501 (~800 kbit/s sustained at
  close range; ECC eating ~20%)

### 15.2 Decimen Optical Transfer — fountain-coded QR at 60 fps, browser-only
- https://www.tomshardware.com/networking/streaming-qr-codes-at-60-fps-achieves-nearly-190-kb-s-data-rate-in-phone-to-phone-tests-browser-based-method-requires-no-app-no-networking-no-pairing-and-no-permissions-beyond-camera-access
  (~128 KB/s handheld, ~187 KB/s on a tripod — stability is the hidden bitrate variable)

### 15.3 Optical Camera Communications background
- Survey: "Optical Camera Communications: Survey, Use Cases, Challenges" —
  https://arxiv.org/abs/1812.01259 (CSK ≈ 5 kbps on smartphones; color-intensity
  modulation ≈ 95 kbps at 1.2 m; rolling-shutter channel discussion)
- Passive screen-to-camera embedding: https://arxiv.org/abs/2403.16185 (receiver
  frame rate must be ≥ transmitter refresh — the Nyquist constraint behind §4)
- ColorBars (LED→camera color shift keying, 2.9–7.7 kbps on phones):
  https://perfecthu.github.io/publications/colorbars-tmc.pdf

### 15.4 Fountain codes and line coding
- M. Luby, "LT Codes," Proc. IEEE FOCS 2002 — the rateless code family used here;
  robust soliton degree distribution
- RFC 6330, RaptorQ Forward Error Correction Scheme — https://www.rfc-editor.org/rfc/rfc6330
  (production-grade fountain code; overkill for byte-sized chunks but the reference
  for systematic design)
- Manchester code — https://en.wikipedia.org/wiki/Manchester_code (the symbol/separator
  scheme in the Far preset is a return-to-zero variant of the same idea)

### 15.5 Phone flashlight Morse (the baseline)
- "Morse Code Torch" — iOS: https://apps.apple.com/us/app/morse-code-torch/id1381259457
- "Morse Code Torch" — Android: https://play.google.com/store/apps/details?id=com.perryoncrack.mcfleshlite
- Two-way camera+flash Morse chat: https://morsesignals.com/
- F-Droid torch Morse encoder: https://f-droid.org/en/packages/org.wbftw.weil.sos_flashlight/
- Phone-as-receiver via camera brightness analysis: https://stackoverflow.com/questions/15576613/
- ESP8266→smartphone Morse at 160 m at night:
  https://www.instructables.com/Transmit-and-Receive-Morse-Code-Using-Light-With-A/

### 15.6 Photodiode vs photoresistor (hardware variant)
- https://forum.arduino.cc/t/photo-diodes-or-photo-resistors-which-is-better/1336462
  (photodiodes respond orders of magnitude faster; LDR rise times of 10–100 ms are
  Morse-only)

### 15.7 Browser camera and torch APIs
- getUserMedia: https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/getUserMedia
- Torch via applyConstraints: https://stackoverflow.com/questions/62703126/
- MediaStreamTrack capabilities rollout: https://oberhofer.co/mediastreamtrack-and-its-capabilities/
  (Safari does not support the Image Capture feature set)

### 15.8 The iOS torch wall
- WebKit Bugzilla #243075, torch track constraint ignored on iOS:
  https://bugs.webkit.org/show_bug.cgi?id=243075
- https://discussions.apple.com/thread/250155955 (camera in Safari, no flash control)
- Native: `AVCaptureDevice.torchMode` / `setTorchModeOn(level:)` — Apple developer docs

### 15.9 Embedded variant parts
- KY-008 laser transmitter (S pin = signal, middle pin unused):
  https://arduinomodules.info/ky-008-laser-transmitter-module/
- UART over laser on ESP32, 40 kbps: https://holly-jackson.com/laser-comms
- ESP32-C3 + 0.42″ OLED pinout (GPIO5/6 I²C, SSD1306 72×40 with (30,12) offset):
  https://www.atomic14.com/2026/02/16/esp32-c3-oled and
  https://emalliab.wordpress.com/2025/02/12/esp32-c3-0-42-oled/
