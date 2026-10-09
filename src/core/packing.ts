import { GROUP_SYMBOLS } from './config';

/**
 * A "group" is 7 payload symbols, each drawn from a k-color palette. The 7
 * symbols are read as a base-k number carrying floor(7·log2 k) bits:
 *   k=2 -> 7 bits, k=3 -> 11 bits, k=4 -> 14 bits.
 * Values >= 2^bits are never transmitted, so seeing one flags a misdecode.
 */
export function bitsPerGroup(k: number): number {
  return Math.floor(GROUP_SYMBOLS * Math.log2(k) + 1e-9);
}

export function groupsFor(nbits: number, k: number): number {
  return Math.ceil(nbits / bitsPerGroup(k));
}

/** value -> 7 base-k digits, most significant first. */
export function encodeGroup(value: number, k: number): number[] {
  const out = new Array<number>(GROUP_SYMBOLS);
  let v = value;
  for (let i = GROUP_SYMBOLS - 1; i >= 0; i--) {
    out[i] = v % k;
    v = Math.floor(v / k);
  }
  return out;
}

/** 7 base-k digits -> value, or null if any digit is unknown/invalid or the value is out of range. */
export function decodeGroup(digits: ArrayLike<number | null>, k: number): number | null {
  let v = 0;
  for (let i = 0; i < GROUP_SYMBOLS; i++) {
    const d = digits[i];
    if (d === null || d === undefined || d < 0 || d >= k) return null;
    v = v * k + d;
  }
  return v < 2 ** bitsPerGroup(k) ? v : null;
}

/** Pack a bit array into groups (zero-padded to a group boundary); returns symbols. */
export function bitsToSymbols(bits: ArrayLike<number>, k: number): number[] {
  const b = bitsPerGroup(k);
  const groups = groupsFor(bits.length, k);
  const out: number[] = [];
  for (let g = 0; g < groups; g++) {
    let v = 0;
    for (let i = 0; i < b; i++) {
      const bit = g * b + i < bits.length ? bits[g * b + i] : 0;
      v = v * 2 + bit;
    }
    out.push(...encodeGroup(v, k));
  }
  return out;
}

/** Unpack symbols (grouped by 7) into bits; a group with any unknown symbol yields unknown bits. */
export function symbolsToBits(symbols: ArrayLike<number | null>, k: number): (number | null)[] {
  const b = bitsPerGroup(k);
  const out: (number | null)[] = [];
  for (let g = 0; g + GROUP_SYMBOLS <= symbols.length; g += GROUP_SYMBOLS) {
    const digits: (number | null)[] = [];
    for (let i = 0; i < GROUP_SYMBOLS; i++) digits.push(symbols[g + i]);
    const v = decodeGroup(digits, k);
    for (let i = b - 1; i >= 0; i--) out.push(v === null ? null : (v >>> i) & 1);
  }
  return out;
}
