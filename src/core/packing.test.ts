import { describe, expect, it } from 'vitest';
import { bitsPerGroup, bitsToSymbols, decodeGroup, encodeGroup, symbolsToBits } from './packing';
import { crc16, crc8 } from './crc';
import { decodeBeacon, decodeHeader, encodeBeacon, encodeHeader, encodeBlock, decodeBlock } from './framing';
import { decodePayload, encodePayload, PayloadType } from './payload';

describe('packing', () => {
  it('bits per group by palette size', () => {
    expect(bitsPerGroup(2)).toBe(7);
    expect(bitsPerGroup(3)).toBe(11);
    expect(bitsPerGroup(4)).toBe(14);
  });

  it.each([2, 3, 4])('round-trips every value for k=%i', (k) => {
    const n = 2 ** bitsPerGroup(k);
    for (let v = 0; v < n; v += 7) {
      expect(decodeGroup(encodeGroup(v, k), k)).toBe(v);
    }
    expect(decodeGroup(encodeGroup(n - 1, k), k)).toBe(n - 1);
  });

  it('rejects out-of-range and unknown digits', () => {
    expect(decodeGroup([2, 2, 2, 2, 2, 2, 2], 3)).toBeNull(); // 2186 >= 2048
    expect(decodeGroup([0, 0, 0, null, 0, 0, 0], 3)).toBeNull();
    expect(decodeGroup([0, 0, 0, 3, 0, 0, 0], 3)).toBeNull();
  });

  it.each([2, 3, 4])('bit stream round-trips through symbols for k=%i', (k) => {
    const bits = Array.from({ length: 123 }, (_, i) => (i * 7919) % 3 === 0 ? 1 : 0);
    const syms = bitsToSymbols(bits, k);
    expect(syms.length % 7).toBe(0);
    const back = symbolsToBits(syms, k);
    expect(back.slice(0, bits.length)).toEqual(bits);
  });

  it('k=3: marks the whole group unknown when one symbol is unknown', () => {
    const bits = new Array(22).fill(1);
    const syms = bitsToSymbols(bits, 3) as (number | null)[];
    syms[3] = null;
    const back = symbolsToBits(syms, 3);
    expect(back.slice(0, 11).every((b) => b === null)).toBe(true);
    expect(back.slice(11, 22).every((b) => b === 1)).toBe(true);
  });
});

describe('crc', () => {
  it('matches known vectors', () => {
    const check = new TextEncoder().encode('123456789');
    expect(crc8(check)).toBe(0xf4);
    expect(crc16(check)).toBe(0x29b1);
  });
});

describe('framing', () => {
  it('beacon round-trips', () => {
    const cfg = { preset: 'mid' as const, palette: 'rgw' as const, fps: 15 as const };
    const bits = encodeBeacon(cfg);
    expect(bits.length).toBe(32);
    expect(decodeBeacon(bits)).toEqual(cfg);
    bits[20] ^= 1;
    expect(decodeBeacon(bits)).toBeNull();
  });

  it('header round-trips and rejects corruption', () => {
    const h = { msgId: 200, length: 4321, epoch: 17, epochChunks: 32 as const, flags: 0 };
    const bits = encodeHeader(h);
    expect(bits.length).toBe(56);
    expect(decodeHeader(bits)).toEqual(h);
    bits[30] ^= 1;
    expect(decodeHeader(bits)).toBeNull();
  });

  it('every epoch size survives the header flags', () => {
    for (const epochChunks of [8, 16, 32, 64] as const) {
      const h = { msgId: 1, length: 9, epoch: 3, epochChunks, flags: 0 };
      expect(decodeHeader(encodeHeader(h))).toEqual(h);
    }
  });

  it('block round-trips; a flipped bit, wrong index or wrong epoch is rejected', () => {
    const bytes = [1, 2, 3, 4, 5, 6, 7, 255];
    const bits = encodeBlock(9, 4, 2, bytes);
    expect(bits.length).toBe(72);
    expect(decodeBlock(bits, 8, 9, 4, 2)).toEqual(bytes);
    expect(decodeBlock(bits, 8, 9, 4, 3)).toBeNull();
    expect(decodeBlock(bits, 8, 9, 5, 2)).toBeNull();
    const bad = bits.slice();
    bad[13] ^= 1;
    expect(decodeBlock(bad, 8, 9, 4, 2)).toBeNull();
    const holey: (number | null)[] = bits.slice();
    holey[40] = null;
    expect(decodeBlock(holey, 8, 9, 4, 2)).toBeNull();
  });
});

describe('symbolsToBits', () => {
  it('for k=2 and k=4 an unknown symbol blanks only its own bits', () => {
    for (const k of [2, 4]) {
      const bits = Array.from({ length: 2 * bitsPerGroup(k) }, (_, i) => (i * 7 + 3) % 5 > 1 ? 1 : 0);
      const syms: (number | null)[] = bitsToSymbols(bits, k);
      expect(symbolsToBits(syms, k)).toEqual(bits);
      syms[3] = null;
      const out = symbolsToBits(syms, k);
      const per = Math.log2(k);
      expect(out.filter((b) => b === null).length).toBe(per);
      expect(out.slice(0, 3 * per)).toEqual(bits.slice(0, 3 * per));
    }
  });
});

describe('payload', () => {
  it('text round-trips', () => {
    const p = { type: PayloadType.Text, text: 'hello across the field ✓' } as const;
    expect(decodePayload(encodePayload(p))).toEqual(p);
  });
  it('file round-trips and detects corruption', () => {
    const data = Uint8Array.from([1, 2, 3, 250]);
    const bytes = encodePayload({ type: PayloadType.File, name: 'notes.txt', data });
    expect(decodePayload(bytes)).toEqual({ type: PayloadType.File, name: 'notes.txt', data });
    bytes[bytes.length - 1] ^= 0xff;
    expect(decodePayload(bytes)).toBeNull();
  });
});
