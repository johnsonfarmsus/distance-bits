import { describe, expect, it } from 'vitest';
import { LTDecoder, LTEncoder, ChunkPlan } from './fountain';
import { Prng } from './prng';

function randomBytes(n: number, seed = 1): Uint8Array {
  const rng = new Prng(seed);
  const out = new Uint8Array(n);
  for (let i = 0; i < n; i++) out[i] = rng.int(256);
  return out;
}

describe('fountain code', () => {
  it('is systematic for the first L chunks', () => {
    const data = randomBytes(50);
    const enc = new LTEncoder(data, 7);
    for (let i = 0; i < 50; i++) expect(enc.chunk(i)).toBe(data[i]);
  });

  it('decodes with zero loss after exactly L chunks', () => {
    const data = randomBytes(200);
    const enc = new LTEncoder(data, 3);
    const dec = new LTDecoder(200, 3);
    for (let c = 0; c < 200; c++) dec.add(c, enc.chunk(c));
    expect(dec.complete).toBe(true);
    expect(dec.result()).toEqual(data);
  });

  it.each([1, 5, 40, 160, 1000])('recovers L=%i with 30%% random loss', (L) => {
    const data = randomBytes(L, L);
    const enc = new LTEncoder(data, 42);
    const dec = new LTDecoder(L, 42);
    const rng = new Prng(99);
    let c = 0;
    while (!dec.complete && c < L * 10 + 100) {
      if (rng.next() > 0.3) dec.add(c, enc.chunk(c));
      c++;
    }
    expect(dec.complete).toBe(true);
    expect(dec.result()).toEqual(data);
    // Received chunks should be within a sane overhead of L.
    expect(dec.received).toBeLessThan(L * 1.6 + 20);
  });

  it('recovers when an entire contiguous block is lost', () => {
    const L = 300;
    const data = randomBytes(L, 5);
    const enc = new LTEncoder(data, 9);
    const dec = new LTDecoder(L, 9);
    for (let c = 0; c < 2000 && !dec.complete; c++) {
      if (c >= 100 && c < 250) continue; // lose 150 of the systematic chunks
      dec.add(c, enc.chunk(c));
    }
    expect(dec.complete).toBe(true);
    expect(dec.result()).toEqual(data);
  });

  it('ignores duplicate chunks', () => {
    const data = randomBytes(10);
    const enc = new LTEncoder(data, 1);
    const dec = new LTDecoder(10, 1);
    for (let i = 0; i < 100; i++) dec.add(0, enc.chunk(0));
    expect(dec.received).toBe(1);
    expect(dec.progress).toBe(1);
  });

  it('produces the same neighbor sets on both ends', () => {
    const a = new ChunkPlan(500, 77);
    const b = new ChunkPlan(500, 77);
    for (let c = 500; c < 600; c++) expect(a.neighbors(c)).toEqual(b.neighbors(c));
    expect(a.neighbors(501)).not.toEqual(new ChunkPlan(500, 78).neighbors(501));
  });
});
