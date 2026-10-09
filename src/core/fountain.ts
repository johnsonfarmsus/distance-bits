import { Prng, chunkSeed } from './prng';

/**
 * Systematic LT fountain code over bytes.
 *
 * Source block i (0 <= i < L) is one byte of the message. Chunk c is:
 *   c <  L : source byte c (degree 1) — the systematic pass
 *   c >= L : XOR of a pseudo-random set of source bytes chosen from
 *            (msgId, c) via a robust soliton degree distribution
 *
 * Both ends derive the composition of chunk c from (msgId, c) alone, so the
 * transmitter can emit chunks forever and the receiver can decode from any
 * sufficiently large subset.
 */

export interface SolitonParams {
  c: number;
  delta: number;
}

const DEFAULT_SOLITON: SolitonParams = { c: 0.05, delta: 0.5 };

/** Cumulative robust soliton distribution for L blocks (index d-1 => P(degree <= d)). */
export function robustSolitonCdf(L: number, p: SolitonParams = DEFAULT_SOLITON): Float64Array {
  if (L <= 1) return new Float64Array([1]);
  const R = p.c * Math.log(L / p.delta) * Math.sqrt(L);
  const rho = new Float64Array(L);
  const tau = new Float64Array(L);
  rho[0] = 1 / L;
  for (let d = 2; d <= L; d++) rho[d - 1] = 1 / (d * (d - 1));
  const spike = Math.max(1, Math.min(L, Math.round(L / R)));
  for (let d = 1; d < spike; d++) tau[d - 1] = R / (d * L);
  tau[spike - 1] = (R * Math.log(R / p.delta)) / L;
  let z = 0;
  for (let i = 0; i < L; i++) z += rho[i] + tau[i];
  const cdf = new Float64Array(L);
  let acc = 0;
  for (let i = 0; i < L; i++) {
    acc += (rho[i] + tau[i]) / z;
    cdf[i] = acc;
  }
  cdf[L - 1] = 1;
  return cdf;
}

export class ChunkPlan {
  private cdf: Float64Array;
  constructor(public readonly L: number, public readonly msgId: number) {
    this.cdf = robustSolitonCdf(L);
  }
  /** Sorted, distinct source indices XORed into chunk c. */
  neighbors(c: number): number[] {
    const L = this.L;
    if (c < L) return [c];
    const rng = new Prng(chunkSeed(this.msgId, c));
    const u = rng.next();
    let d = 1;
    while (d < L && this.cdf[d - 1] < u) d++;
    const set = new Set<number>();
    while (set.size < d) set.add(rng.int(L));
    return Array.from(set).sort((a, b) => a - b);
  }
}

export class LTEncoder {
  private plan: ChunkPlan;
  constructor(private data: Uint8Array, msgId: number) {
    this.plan = new ChunkPlan(data.length, msgId);
  }
  chunk(c: number): number {
    let v = 0;
    for (const i of this.plan.neighbors(c)) v ^= this.data[i];
    return v;
  }
}

interface Equation {
  idx: number[]; // unsolved unknowns, sorted
  val: number;
}

export class LTDecoder {
  private plan: ChunkPlan;
  private solved: Int16Array; // -1 = unknown
  private solvedCount = 0;
  private eqs = new Map<number, Equation>();
  private byUnknown: Set<number>[];
  private seen = new Set<number>();
  private nextEqId = 0;
  private lastGaussianAt = 0;
  received = 0;

  constructor(public readonly L: number, public readonly msgId: number) {
    this.plan = new ChunkPlan(L, msgId);
    this.solved = new Int16Array(L).fill(-1);
    this.byUnknown = Array.from({ length: L }, () => new Set<number>());
  }

  get progress(): number {
    return this.solvedCount;
  }
  get complete(): boolean {
    return this.solvedCount === this.L;
  }
  get pending(): number {
    return this.eqs.size;
  }

  result(): Uint8Array | null {
    if (!this.complete) return null;
    return Uint8Array.from(this.solved);
  }

  /** Feed chunk c with value v. Returns true if it was new information. */
  add(c: number, v: number): boolean {
    if (this.seen.has(c) || this.complete) return false;
    this.seen.add(c);
    this.received++;
    const idx: number[] = [];
    let val = v & 0xff;
    for (const i of this.plan.neighbors(c)) {
      if (this.solved[i] >= 0) val ^= this.solved[i];
      else idx.push(i);
    }
    if (idx.length === 0) return false;
    this.insert({ idx, val });
    if (!this.complete && this.eqs.size >= this.L - this.solvedCount) this.gaussian();
    return true;
  }

  private insert(eq: Equation): void {
    const queue: Equation[] = [eq];
    while (queue.length) {
      const e = queue.pop()!;
      // Unknowns may have been solved while this equation sat in the queue.
      if (e.idx.some((k) => this.solved[k] >= 0)) {
        for (const k of e.idx) if (this.solved[k] >= 0) e.val ^= this.solved[k];
        e.idx = e.idx.filter((k) => this.solved[k] < 0);
      }
      if (e.idx.length === 0) continue;
      if (e.idx.length === 1) {
        const u = e.idx[0];
        if (this.solved[u] >= 0) continue;
        this.solved[u] = e.val;
        this.solvedCount++;
        for (const id of Array.from(this.byUnknown[u])) {
          const other = this.eqs.get(id)!;
          this.eqs.delete(id);
          for (const k of other.idx) this.byUnknown[k].delete(id);
          other.idx = other.idx.filter((k) => k !== u);
          other.val ^= e.val;
          queue.push(other);
        }
        this.byUnknown[u].clear();
      } else {
        const id = this.nextEqId++;
        this.eqs.set(id, e);
        for (const k of e.idx) this.byUnknown[k].add(id);
      }
    }
  }

  /** Fallback when peeling stalls: solve the remaining unknowns over GF(2) by elimination. */
  private gaussian(): void {
    const unknowns: number[] = [];
    for (let i = 0; i < this.L; i++) if (this.solved[i] < 0) unknowns.push(i);
    const n = unknowns.length;
    if (n === 0 || n > 2048) return;
    if (this.eqs.size < this.lastGaussianAt + Math.max(4, n >> 4)) return;
    this.lastGaussianAt = this.eqs.size;
    const col = new Map<number, number>();
    unknowns.forEach((u, i) => col.set(u, i));
    const words = Math.ceil(n / 32);
    const rows: { bits: Uint32Array; val: number }[] = [];
    for (const e of this.eqs.values()) {
      const bits = new Uint32Array(words);
      for (const k of e.idx) {
        const ci = col.get(k)!;
        bits[ci >> 5] |= 1 << (ci & 31);
      }
      rows.push({ bits, val: e.val });
    }
    // Incremental reduced row echelon form: every stored pivot row has exactly one
    // bit among the pivoted columns, so a new row is reduced in one pass and a
    // dependent row reduces to nothing.
    const pivotRow: ((typeof rows)[number] | null)[] = new Array(n).fill(null);
    const bit = (r: { bits: Uint32Array }, c: number) => (r.bits[c >> 5] >>> (c & 31)) & 1;
    let rank = 0;
    for (const row of rows) {
      for (let ci = 0; ci < n; ci++) {
        const p = pivotRow[ci];
        if (p && bit(row, ci)) {
          for (let w = 0; w < words; w++) row.bits[w] ^= p.bits[w];
          row.val ^= p.val;
        }
      }
      let lead = -1;
      for (let ci = 0; ci < n; ci++) if (bit(row, ci)) { lead = ci; break; }
      if (lead < 0) continue;
      for (let cj = 0; cj < n; cj++) {
        const q = pivotRow[cj];
        if (q && bit(q, lead)) {
          for (let w = 0; w < words; w++) q.bits[w] ^= row.bits[w];
          q.val ^= row.val;
        }
      }
      pivotRow[lead] = row;
      rank++;
    }
    if (rank < n) return; // rank-deficient, wait for more chunks
    for (let i = 0; i < n; i++) {
      this.solved[unknowns[i]] = pivotRow[i]!.val;
    }
    this.solvedCount = this.L;
    this.eqs.clear();
    for (const s of this.byUnknown) s.clear();
  }
}
