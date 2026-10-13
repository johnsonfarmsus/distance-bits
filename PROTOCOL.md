# distance-bits wire protocol (as implemented)

This is the authoritative description of what the code does: `src/core`
(TypeScript reference) and `app/lib/core` (the Dart port the app runs, checked
against the TypeScript by golden vectors). `DESIGN.md` is the original reasoning;
where the two differ, this file wins. Where the app's receiver goes further than
the web one (screen finding, exposure), that's noted below.

## Colors and cells

Physical colors: K (black), W, R, G, B. Black is never a payload color; it is the
marker. Payload palettes (the "mode" / blue toggle):

| Palette | Symbols            | k | Bits per 7-symbol group |
|---------|--------------------|---|--------------------------|
| `wr`    | W=0, R=1           | 2 | 7  |
| `rgw`   | R=0, G=1, W=2      | 3 | 11 |
| `rgbw`  | R=0, G=1, B=2, W=3 | 4 | 14 |

Seven symbols are read as a base-k number, most significant first. Values at or
above 2^bits are never sent; seeing one means a misdecode and the group is dropped.
For k = 2 and 4 this is plain binary (1 or 2 bits per symbol), so the receiver maps
each symbol to its own bits and an unknown symbol blanks only those bits. For k = 3
one unknown symbol blanks the whole group.

## Presets

| Preset | Grid | Frame layout | Symbols / frame | Marker | Header copies | Chunks / block | Default |
|--------|------|--------------|-----------------|--------|---------------|----------------|---------|
| near   | 2×4  | one black cell walks raster positions 0..7 (position = seq mod 8), the other 7 cells are one group | 7 | position mod 8 | 2 | 4 | rgbw, 30 fps |
| mid    | 1×2  | black cell alternates top/bottom (seq mod 2); the other cell is one symbol | 1 | position mod 2 | 3 | 2 | rgbw, 30 fps |
| far    | 1×1  | frames alternate: one symbol (whole screen), then all black | 0.5 | lit/black = seq mod 2 | 2 | 2 | wr, 15 fps |

`seq` is the transmitter's monotonic frame counter across everything it sends.

## Transmission sequence

```
epoch 0:  BEACON  HEADER×r  E chunks in blocks
epoch 1:          HEADER×r  E chunks in blocks
epoch 2:          HEADER×r  E chunks in blocks
epoch 3:          HEADER×r  E chunks in blocks
epoch 4:  BEACON  HEADER×r  E chunks in blocks
...forever, until the sender is stopped.
```

**Beacon** (32 bits) — always sent as 1×1 frames, W=0 / R=1, each bit followed by a
black frame, regardless of preset:

```
sync16 = 0xB5C2 | preset(2) palette(2) fps(2) reserved(2) | crc8(first 3 bytes)
```

**Header** (56 bits) — sent in the preset's own grid and palette, packed through the
group encoder (zero-padded to a group boundary), repeated `r` times back-to-back:

```
sync8 = 0xD5 | msgId(8) | length(16) | epoch(8) | flags(8) | crc8(first 6 bytes)
flags: bits 0-1 = epoch size E code (0:8, 1:16, 2:32, 3:64 chunks); bit 7 = encrypted; bits 2-6 reserved, 0
```

(Sync was 0xD3 before block checksums were added; old and new builds don't talk.)

**Epoch size** — `E` = the smallest of 8/16/32/64 that is at least 1.5 × payload
length, capped at 64. Short messages get short epochs, so a late receiver waits less.

**Chunks** — one byte each, chunk index `c = (epoch mod 256)·E + i`. Indices wrap with
the 8-bit epoch, so after 256 epochs the same chunks repeat (harmless duplicates).

**Blocks** — the epoch's chunks are sent in blocks of `n` (the preset's chunks/block):

```
n chunk bytes | crc8(msgId, epoch mod 256, blockIndex, the n bytes)
```

All of an epoch's blocks are packed through the group encoder as one bitstream
(zero-padded to a group boundary). A block with any unknown bit, or a failed CRC, is
dropped whole. This turns misread colours into missing chunks, which the fountain
code handles, instead of wrong chunks, which it can't. Keying the CRC on
msgId/epoch/index also catches a stream that has slipped by a frame.

## Fountain code

Systematic LT code over the payload bytes (L = length):

- chunk `c < L` is payload byte `c`
- chunk `c ≥ L` is the XOR of a set of payload bytes chosen by a PRNG seeded from
  `(msgId, c)`; degree drawn from a robust soliton distribution (c=0.05, δ=0.5)

The receiver peels; when peeling stalls and it has at least as many equations as
unknowns it runs GF(2) elimination on the remainder (≤ 2048 unknowns).

## Payload container

```
type(1) | crc16(body)(2) | body
  type 0 text  : UTF-8
  type 1 file  : nameLen(1) name data
  type 2 image : mimeLen(1) mime data
```

Max 65535 bytes total.

## Encryption (chat codes)

Optional, per chat. Two people agree a 3-character code (A–Z, 0–9, case-insensitive).
When header flag bit 7 is set, the fountain-coded bytes are:

```
nonce(4, random per message) | AES-128-CTR(key, iv = nonce ‖ 0x00×12)(payload container)
key = PBKDF2-HMAC-SHA256(password = code (upper-case, UTF-8), salt = "distance-bits/v1",
                         iterations = 50 000, length = 16 bytes)
```

The receiver decrypts with its chat's key and checks the container's CRC-16: a
failure means a different code (or, rarely, a corrupt decode), and the message is
reported as locked rather than shown. Known-answer vectors from Node's crypto are
in `app/test/crypto_vectors.json`.

Threat model: stops a nearby onlooker running the same app from reading along. It
does not prove who sent a message, and with only 46 656 possible codes a determined
attacker with a recording can brute-force it; the slow key derivation only makes
that take a while.

The Flutter app implements this (`app/lib/core/secure.dart`). The web receiver
recognises the flag and reports encrypted messages as locked.

## Delivery confirmation (return path)

When the receiver decodes a message (including a repeat it already had), it blinks
its rear flashlight, which faces the sender while listening: on/off every 125 ms
for 3 s. The sender's front camera faces the receiver from the same side as the
transmitting screen. While sending, it runs at its shortest shutter and lowest
ISO, so only a torch seen head-on saturates. The sender declares the message
delivered after 6 consecutive on/off runs of 85–200 ms from a compact, saturated
white spot that stays in roughly one place (≤15 % of the frame between blinks).
It then stops transmitting.

The ack is not tied to a message id; with one sender and one receiver that's
enough. Without a working torch or front camera the sender simply keeps sending
until stopped by hand, as before. Implemented in `app/lib/core/ack.dart` (detector),
`app/lib/ui/ack_flasher.dart` and `app/lib/ui/transmit_screen.dart`.

## Receiver

1. **Finding the screen** (app: `ScreenFinder` in `vision.dart`). The camera runs
   at 120 fps (60 if unavailable) at 720p with a fixed 1/1000 s shutter; ISO is
   steered so the brightest cell sits near 205/255. The screen is located on a
   ~240 px-wide subsampled copy of each frame by what makes it unusual: its colour
   keeps changing. Each pixel accumulates how much its hue jumps between lit
   captures (fading with a 0.5 s time constant), and the most active connected
   patch is the screen. Lamps and windows are bright but don't change hue. The box
   reported is the connected bright region around that patch (pixels at least 60%
   of the peak and no more than 90 levels below it). Through runs of one colour
   (no hue changes) it keeps following the last box for up to 4 s. A new box is
   accepted only if it's at least 12 coarse pixels, overlaps the previous box and
   is between 0.25× and 2.5× its area. A box that is only a band across the
   previous one (a capture taken while the display was refreshing) is answered
   with the whole previous box. If boxes keep being rejected for over a second
   while the screen is clearly switching colour, the finder starts over.
   The web receiver uses the simpler "largest bright blob" (25% above mean).
2. **Tracking and sampling.** The box is the union of the last 400 ms of
   detections, held 1.5 s through black frames. Colours are read at full camera
   resolution from the centre 50% of each cell of a 2×4 grid. In Far mode only the
   middle half of the box is read, since the colour is the same everywhere on the
   screen and the box can be off by a pixel or so. Each sample is classified
   against a running black/white calibration: black if its brightest channel is
   below 35% of the span; otherwise white if no channel share exceeds 45%;
   otherwise the dominant channel.
3. **Accepting frames.** A frame is accepted when two consecutive captures agree
   (one, if the camera runs at less than 1.7× the transmit rate) and differ from
   the last accepted frame. In Far mode "agree" compares the screen's majority
   colour (3 of 4 samples), not the raw samples, so a box shifting mid-symbol
   can't make one symbol count twice; captures without a clear majority are
   skipped.
4. **Configuration**, in priority order: manual > beacon > auto. Auto infers the
   preset from frame structure (uniform → far; halves uniform with one black →
   mid; exactly one black cell → near) over a 12-frame window. The palette comes
   from which colours have been seen (sticky: upgrades on 3 sightings in 240
   frames, downgrades only after a full window without). The frame rate comes from
   the lower quartile of accepted-frame spacing. Once a valid header has been read
   the preset and palette are confirmed and auto-detection only refines the frame
   rate.
5. **Frame counting.** Each parsed frame's marker gives `seq mod M`; capture timing
   gives the number of elapsed frames; the two are reconciled and any gap is
   filled with unknown symbols.
6. **Decoding.** The symbol stream is searched for a header ending at the current
   position; the `r` header copies are merged (newest copy wins, older copies fill
   its holes). After a header, any further consistent copies are dropped, then the
   epoch's groups are read one at a time. Each block is checked and fed to the
   decoder as soon as its last group arrives, so a short message can finish
   mid-epoch. After the last block, back to searching.
7. **Completion.** On full decode the container's CRC-16 is checked. For an
   encrypted message the app first tries each of its chat keys; if none gives a
   valid CRC the message is reported once as locked (sent under a code this phone
   doesn't have) and the rest of it is ignored. For an unencrypted message a
   failed CRC means a misread chunk got through: the decoder is discarded and
   decoding starts over from the chunks that follow. The sender loops, so a clean
   pass arrives eventually.
