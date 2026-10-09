# distance-bits wire protocol (as implemented)

This is the authoritative description of what `src/core` does. `DESIGN.md` is the
reasoning; where the two differ, this file wins.

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
flags: bits 0-1 = epoch size E code (0:8, 1:16, 2:32, 3:64 chunks); bits 2-7 reserved, 0
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

## Receiver

1. Vision: find the largest bright blob (max-channel threshold, 25% above mean),
   track its bbox as the union of the last 400 ms of detections (held 1.5 s through
   black frames), sample the center 50% of each cell in a 2×4 grid, classify each
   cell against a running black/white calibration: black if max channel is below 35%
   of the span, otherwise white if no channel share exceeds 45%, otherwise the
   dominant channel.
2. Accept a frame when two consecutive captures classify identically and differ
   from the last accepted frame (the marker moves every frame, so consecutive
   transmitted frames are never identical).
3. Configuration, in priority order: manual > beacon > auto. Auto infers the preset
   from frame structure (uniform → far; halves uniform with one black → mid; exactly
   one black cell → near) over a 12-frame window, the palette from which colors have
   been seen (sticky: upgrades on 3 sightings in 240 frames, downgrades only after a
   full window without), and the frame rate from accepted-frame timing.
4. Frame counting: each parsed frame's marker gives `seq mod M`; capture timing gives
   the number of elapsed frames; the two are reconciled and any gap is filled with
   unknown symbols.
5. The symbol stream is searched for a header ending at the current position; the
   `r` header copies are merged (newest copy wins, older copies fill its holes).
   After a header, any further consistent copies are dropped, then the epoch's groups
   are read one at a time. Each block is checked and fed to the decoder as soon as
   its last group arrives, so a short message can finish mid-epoch. After the last
   block, back to searching.
6. On full decode the container's CRC-16 is checked. If it fails (a misread chunk
   reached the decoder), the decoder is discarded and decoding starts over from the
   chunks that follow; the sender loops, so a clean pass arrives eventually.
