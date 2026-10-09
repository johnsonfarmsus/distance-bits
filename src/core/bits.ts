/** MSB-first bit writer over a growable byte buffer. */
export class BitWriter {
  private bits: number[] = [];
  write(value: number, nbits: number): void {
    for (let i = nbits - 1; i >= 0; i--) this.bits.push((value >>> i) & 1);
  }
  writeBytes(bytes: ArrayLike<number>): void {
    for (let i = 0; i < bytes.length; i++) this.write(bytes[i], 8);
  }
  get length(): number {
    return this.bits.length;
  }
  toBits(): number[] {
    return this.bits.slice();
  }
  toBytes(): Uint8Array {
    const out = new Uint8Array(Math.ceil(this.bits.length / 8));
    for (let i = 0; i < this.bits.length; i++) if (this.bits[i]) out[i >> 3] |= 0x80 >> (i & 7);
    return out;
  }
}

/** MSB-first bit reader over a bit array (values 0/1; null = unknown). */
export class BitReader {
  private pos = 0;
  constructor(private bits: ArrayLike<number | null>) {}
  /** Returns null if any bit in the field is unknown. */
  read(nbits: number): number | null {
    let v = 0;
    let unknown = false;
    for (let i = 0; i < nbits; i++) {
      const b = this.bits[this.pos++];
      if (b === null || b === undefined) unknown = true;
      else v = (v << 1) | b;
    }
    return unknown ? null : v >>> 0;
  }
  get remaining(): number {
    return this.bits.length - this.pos;
  }
}

export function bitsToBytes(bits: ArrayLike<number | null>, nbytes: number): (number | null)[] {
  const out: (number | null)[] = [];
  const r = new BitReader(bits);
  for (let i = 0; i < nbytes; i++) out.push(r.read(8));
  return out;
}

export function bytesToBits(bytes: ArrayLike<number>): number[] {
  const w = new BitWriter();
  w.writeBytes(bytes);
  return w.toBits();
}
