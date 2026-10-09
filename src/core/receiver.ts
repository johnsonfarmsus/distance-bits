import { Color } from './colors';
import type { Config, Fps, PaletteName, PresetName } from './config';
import { FPS_VALUES, blockBits, GROUP_SYMBOLS, PALETTES, PRESETS, framePeriodMs, symbolOf } from './config';
import { LTDecoder } from './fountain';
import { BEACON_BITS, HEADER_BITS, decodeBeacon, decodeBlock, decodeHeader, encodeHeader, type Header } from './framing';
import { bitsToSymbols, groupsFor, symbolsToBits } from './packing';
import { decodePayload, type Payload } from './payload';

/** One accepted camera frame, already reduced to per-cell colors (null = unclassifiable). */
export interface Observation {
  t: number;
  cells: (Color | null)[];
}

export type ConfigSource = 'beacon' | 'manual' | 'auto';

export interface ReceiverEvents {
  onConfig?(cfg: Config, source: ConfigSource): void;
  onHeader?(h: Header): void;
  onProgress?(solved: number, total: number, chunksReceived: number): void;
  onDone?(payload: Payload, bytes: Uint8Array, h: Header): void;
  /** The fountain decode completed but the payload CRC failed; the receiver has reset and keeps listening. */
  onCrcFail?(bytes: Uint8Array, h: Header): void;
  onFrame?(entry: FrameLog): void;
}

export interface FrameLog {
  t: number;
  seq: number | null;
  marker: number | null;
  lost: number;
  kind: 'beacon-bit' | 'separator' | 'payload' | 'unparsed';
  symbols: string;
  state: string;
}

export interface ReceiverStats {
  observed: number;
  parsed: number;
  unparsed: number;
  lostFrames: number;
  headers: number;
  epochs: number;
  chunksAdded: number;
  chunksUnknown: number;
  beacons: number;
  /** Blocks dropped because a symbol was missing. */
  blocksLost: number;
  /** Blocks dropped because their CRC-8 failed (misread colours). */
  blocksBad: number;
  crcFailures: number;
}

type State = 'search' | 'epoch';

const AUTO_WINDOW = 12;
const AUTO_MIN = 6;
const COLOR_WINDOW = 240;
const COLOR_MIN = 3;

/**
 * What kind of transmitted frame does this look like, judged purely by structure?
 *   far  : the whole screen is one color
 *   mid  : top half and bottom half each uniform, exactly one of them black
 *   near : exactly one black cell, everything else lit
 */
export function detectStructure(cells: (Color | null)[], uniform: Color | undefined): PresetName | null {
  if (uniform !== undefined) return 'far';
  const n = cells.length;
  if (n % 2 === 0 && n >= 2) {
    const top = uniformColor(cells.slice(0, n / 2));
    const bottom = uniformColor(cells.slice(n / 2));
    if (top !== undefined && bottom !== undefined && (top === Color.K) !== (bottom === Color.K)) return 'mid';
  }
  let k = 0;
  for (const c of cells) {
    if (c === null) return null;
    if (c === Color.K) k++;
  }
  return k === 1 ? 'near' : null;
}

/**
 * Consumes accepted frames and drives the fountain decoder.
 *
 * search : looking for a header at the end of the symbol buffer (any alignment)
 * epoch  : reading the blocks that follow a header; each block is checked and fed
 *          to the decoder as soon as its last group arrives
 * A beacon (uniform W/R frames with black separators) can arrive at any time and
 * (re)configures the receiver.
 */
export class Receiver {
  config: Config | null = null;
  header: Header | null = null;
  decoder: LTDecoder | null = null;
  done = false;
  stats: ReceiverStats = {
    observed: 0, parsed: 0, unparsed: 0, lostFrames: 0, headers: 0, epochs: 0, chunksAdded: 0, chunksUnknown: 0, beacons: 0, blocksLost: 0, blocksBad: 0, crcFailures: 0,
  };

  private state: State = 'search';
  private buf: (number | null)[] = [];
  private lastSeq: number | null = null;
  private lastT = 0;
  private beaconBits: number[] = [];
  private blocksTotal = 0;
  private blockChunks = 1;
  private blocksDone = 0;
  private groupsDone = 0;
  private epochBitBuf: (number | null)[] = [];
  private headerSyms: number[] = [];
  private copiesLeft = 0;
  configSource: ConfigSource | null = null;
  private autoWindow: { t: number; kind: PresetName | null }[] = [];
  private colorHistory: number[] = [];
  /**
   * A header decoded under the current config: preset and palette are proven, so
   * auto-detection stops second-guessing them (it may still refine fps).
   */
  private confirmed = false;

  constructor(private events: ReceiverEvents = {}, manualConfig?: Config) {
    if (manualConfig) this.setConfig(manualConfig, 'manual');
  }

  /**
   * Grid the vision layer should sample with. Always the finest grid (2×4): the
   * receiver reduces it to 1×2 or 1×1 itself, which keeps structure detection
   * working whatever the current preset guess is.
   */
  samplingGrid(): { cols: number; rows: number } {
    return { cols: PRESETS.near.cols, rows: PRESETS.near.rows };
  }

  setConfig(cfg: Config, source: ConfigSource): void {
    this.config = cfg;
    this.configSource = source;
    this.confirmed = false;
    this.resetStream();
    this.events.onConfig?.(cfg, source);
  }

  private resetStream(): void {
    this.state = 'search';
    this.buf = [];
    this.lastSeq = null;
    this.blocksTotal = 0;
  }

  observe(obs: Observation): void {
    this.stats.observed++;
    const uniform = uniformColor(obs.cells);
    if (this.configSource !== 'manual' && this.configSource !== 'beacon') this.autoDetect(obs, uniform);
    obs = { t: obs.t, cells: this.reduceCells(obs.cells) };
    if (uniform !== undefined) {
      this.onUniform(uniform, obs);
      if (this.config?.preset !== 'far') return;
    }
    if (!this.config) {
      this.log(obs, null, null, 0, 'unparsed', '');
      return;
    }
    const parsed = this.parse(obs.cells, uniform);
    if (!parsed) {
      this.stats.unparsed++;
      this.log(obs, null, null, 0, 'unparsed', '');
      return;
    }
    this.stats.parsed++;
    const { seq, lost } = this.trackSeq(obs.t, parsed.marker);
    this.stats.lostFrames += lost;
    for (let s = this.lastSeqBefore(seq, lost); s < seq; s++) {
      for (let i = 0; i < this.symbolsAt(s); i++) this.push(null);
    }
    for (const s of parsed.symbols) this.push(s);
    this.log(obs, seq, parsed.marker, lost, parsed.symbols.length ? 'payload' : 'separator', parsed.symbols.map((s) => (s === null ? '?' : String(s))).join(''));
  }

  /** Collapse a 2×4 sample to the configured preset's cell count (a non-uniform region becomes null). */
  private reduceCells(cells: (Color | null)[]): (Color | null)[] {
    const cfg = this.config;
    if (!cfg) return cells;
    const want = PRESETS[cfg.preset].cols * PRESETS[cfg.preset].rows;
    if (cells.length === want) return cells;
    if (cfg.preset === 'far') return [uniformColor(cells) ?? null];
    if (cfg.preset === 'mid' && cells.length % 2 === 0) {
      const half = cells.length / 2;
      return [uniformColor(cells.slice(0, half)) ?? null, uniformColor(cells.slice(half)) ?? null];
    }
    return cells;
  }

  // ---- structure-based auto configuration ---------------------------------

  /**
   * Infers preset (from frame structure), palette (from colors seen) and frame
   * rate (from accepted-frame timing) without needing an intact beacon. Only
   * used until a beacon or the user provides a config.
   */
  private autoDetect(obs: Observation, uniform: Color | undefined): void {
    const kind = detectStructure(obs.cells, uniform);
    let hasB = false, hasG = false;
    for (const c of obs.cells) {
      if (c === Color.B) hasB = true;
      if (c === Color.G) hasG = true;
    }
    this.autoWindow.push({ t: obs.t, kind });
    if (this.autoWindow.length > AUTO_WINDOW) this.autoWindow.shift();
    this.colorHistory.push((hasB ? 2 : 0) | (hasG ? 1 : 0));
    if (this.colorHistory.length > COLOR_WINDOW) this.colorHistory.shift();
    if (this.autoWindow.length < AUTO_MIN) return;

    const votes: Record<string, number> = {};
    for (const e of this.autoWindow) if (e.kind) votes[e.kind] = (votes[e.kind] ?? 0) + 1;
    const [preset, n] = (Object.entries(votes).sort((a, b) => b[1] - a[1])[0] ?? [null, 0]) as [PresetName | null, number];
    if (!preset || n < AUTO_MIN) return;

    // Palette is sticky: upgrade as soon as a color is seen a few times, downgrade
    // only once a long window has gone by without it.
    let blue = 0, green = 0;
    for (const h of this.colorHistory) {
      if (h & 2) blue++;
      if (h & 1) green++;
    }
    const cur = this.config;
    let palette: PaletteName = cur?.palette ?? 'wr';
    if (blue >= COLOR_MIN) palette = 'rgbw';
    else if (green >= COLOR_MIN) palette = palette === 'rgbw' && this.colorHistory.length < COLOR_WINDOW ? 'rgbw' : 'rgw';
    else if (this.colorHistory.length >= COLOR_WINDOW) palette = 'wr';

    // Frame rate from accepted-frame spacing. Missed frames only ever make gaps
    // longer, so use the lower quartile, not the mode: one clean consecutive pair
    // in four is enough.
    const dts: number[] = [];
    for (let i = 1; i < this.autoWindow.length; i++) {
      const dt = this.autoWindow[i].t - this.autoWindow[i - 1].t;
      if (dt > 0) dts.push(dt);
    }
    dts.sort((a, b) => a - b);
    let fps = cur?.fps ?? FPS_VALUES[0];
    if (dts.length >= 4) {
      const dt = dts[dts.length >> 2];
      fps = FPS_VALUES.reduce((best, c) => (Math.abs(1000 / c - dt) < Math.abs(1000 / best - dt) ? c : best), FPS_VALUES[0]);
    }

    const cfg: Config = { preset, palette, fps };
    if (cur && cur.preset === cfg.preset && cur.palette === cfg.palette && cur.fps === cfg.fps) return;
    // An fps-only change re-times frame counting; it doesn't invalidate symbols already read.
    if (cur && (this.confirmed || (cur.preset === cfg.preset && cur.palette === cfg.palette))) {
      if (cur.fps !== fps) this.config = { ...cur, fps };
      return;
    }
    // Changing preset needs a decisive vote; palette/fps changes go through as soon as they're stable.
    if (cur && cur.preset !== cfg.preset && n < AUTO_WINDOW - 2) return;
    this.setConfig(cfg, 'auto');
  }

  // ---- beacon -------------------------------------------------------------

  private onUniform(c: Color, obs: Observation): void {
    if (c === Color.K) return; // separator
    if (c !== Color.W && c !== Color.R) {
      this.beaconBits = [];
      return;
    }
    this.beaconBits.push(c === Color.R ? 1 : 0);
    if (this.beaconBits.length > BEACON_BITS) this.beaconBits.shift();
    if (this.beaconBits.length === BEACON_BITS) {
      const cfg = decodeBeacon(this.beaconBits);
      if (cfg) {
        this.stats.beacons++;
        this.beaconBits = [];
        this.setConfig(cfg, 'beacon');
        this.log(obs, null, null, 0, 'beacon-bit', 'BEACON');
        return;
      }
    }
    if (this.config?.preset !== 'far') this.log(obs, null, null, 0, 'beacon-bit', String(c === Color.R ? 1 : 0));
  }

  // ---- frame parsing ------------------------------------------------------

  private parse(cells: (Color | null)[], uniform: Color | undefined): { marker: number; symbols: (number | null)[] } | null {
    const cfg = this.config!;
    const pal = cfg.palette;
    if (cfg.preset === 'far') {
      if (uniform === undefined) return null;
      if (uniform === Color.K) return { marker: 1, symbols: [] };
      const s = symbolOf(pal, uniform);
      return { marker: 0, symbols: [s < 0 ? null : s] };
    }
    const p = PRESETS[cfg.preset];
    if (cells.length !== p.cols * p.rows) return null;
    let marker = -1;
    for (let i = 0; i < cells.length; i++) {
      if (cells[i] === Color.K) {
        if (marker >= 0) return null; // two black cells: not a payload frame
        marker = i;
      }
    }
    if (marker < 0) return null;
    const symbols: (number | null)[] = [];
    for (let i = 0; i < cells.length; i++) {
      if (i === marker) continue;
      const c = cells[i];
      const s = c === null ? -1 : symbolOf(pal, c);
      symbols.push(s < 0 ? null : s);
    }
    return { marker, symbols };
  }

  // ---- sequence tracking --------------------------------------------------

  private trackSeq(t: number, marker: number): { seq: number; lost: number } {
    const cfg = this.config!;
    const M = PRESETS[cfg.preset].markerPeriod;
    if (this.lastSeq === null) {
      this.lastSeq = marker;
      this.lastT = t;
      return { seq: marker, lost: 0 };
    }
    const period = framePeriodMs(cfg.fps);
    const dt = Math.max(1, Math.round((t - this.lastT) / period));
    const cand = this.lastSeq + dt;
    const r = (((marker - cand) % M) + M) % M;
    // Two candidates consistent with the marker: cand+r and cand+r-M. Prefer the
    // one nearer the timing estimate, and never go backwards.
    const up = cand + r;
    const down = up - M;
    let seq = down > this.lastSeq && cand - down <= up - cand ? down : up;
    while (seq <= this.lastSeq) seq += M;
    const lost = seq - this.lastSeq - 1;
    this.lastSeq = seq;
    this.lastT = t;
    return { seq, lost };
  }

  private lastSeqBefore(seq: number, lost: number): number {
    return seq - lost;
  }

  private symbolsAt(seq: number): number {
    const cfg = this.config!;
    if (cfg.preset === 'near') return GROUP_SYMBOLS;
    if (cfg.preset === 'mid') return 1;
    return seq % 2 === 0 ? 1 : 0;
  }

  // ---- symbol stream ------------------------------------------------------

  private push(sym: number | null): void {
    this.buf.push(sym);
    const k = PALETTES[this.config!.palette].length;
    if (this.state === 'search') {
      const one = groupsFor(HEADER_BITS, k) * GROUP_SYMBOLS;
      const rep = PRESETS[this.config!.preset].headerRepeat;
      const need = one * rep;
      if (this.buf.length > need * 3) this.buf.splice(0, this.buf.length - need * 2);
      if (this.buf.length < one) return;
      // Merge the repeated copies: the newest copy wins, earlier copies only fill its holes.
      const merged: (number | null)[] = this.buf.slice(this.buf.length - one);
      for (let r = 1; r < rep && merged.includes(null); r++) {
        const off = this.buf.length - one * (r + 1);
        if (off < 0) break;
        for (let i = 0; i < one; i++) if (merged[i] === null) merged[i] = this.buf[off + i];
      }
      if (merged.includes(null)) return;
      const h = decodeHeader(symbolsToBits(merged, k));
      if (!h) return;
      this.onHeader(h);
      this.buf = [];
      this.state = 'epoch';
      this.blockChunks = PRESETS[this.config!.preset].blockChunks;
      this.blocksTotal = h.epochChunks / this.blockChunks;
      this.blocksDone = 0;
      this.groupsDone = 0;
      this.epochBitBuf = [];
      // The header we matched may have been an early copy; later copies still to
      // arrive must be recognised and dropped rather than read as payload.
      this.headerSyms = bitsToSymbols(encodeHeader(h), k);
      this.copiesLeft = rep - 1;
    } else {
      if (this.copiesLeft > 0) {
        const n = this.headerSyms.length;
        if (this.buf.length < n) return;
        let consistent = true;
        for (let i = 0; i < n && consistent; i++) if (this.buf[i] !== null && this.buf[i] !== this.headerSyms[i]) consistent = false;
        if (consistent) {
          this.buf.splice(0, n);
          this.copiesLeft--;
          if (this.copiesLeft > 0) return;
        } else {
          this.copiesLeft = 0;
        }
      }
      this.drainEpoch(k);
    }
  }

  /** Turn every complete group into bits and every complete block into chunks. */
  private drainEpoch(k: number): void {
    const B = blockBits(this.blockChunks);
    while (this.blocksDone < this.blocksTotal && this.buf.length >= (this.groupsDone + 1) * GROUP_SYMBOLS) {
      const g = this.buf.slice(this.groupsDone * GROUP_SYMBOLS, (this.groupsDone + 1) * GROUP_SYMBOLS);
      this.groupsDone++;
      for (const b of symbolsToBits(g, k)) this.epochBitBuf.push(b);
      while (this.blocksDone < this.blocksTotal && this.epochBitBuf.length >= (this.blocksDone + 1) * B) {
        const bits = this.epochBitBuf.slice(this.blocksDone * B, (this.blocksDone + 1) * B);
        this.finishBlock(bits, this.blocksDone);
        this.blocksDone++;
      }
    }
    if (this.blocksDone >= this.blocksTotal) {
      this.stats.epochs++;
      this.buf = [];
      this.state = 'search';
    }
  }

  private finishBlock(bits: (number | null)[], block: number): void {
    const h = this.header!;
    const n = this.blockChunks;
    const bytes = decodeBlock(bits, n, h.msgId, h.epoch, block);
    if (!bytes) {
      if (bits.includes(null)) this.stats.blocksLost++;
      else this.stats.blocksBad++;
      this.stats.chunksUnknown += n;
      return;
    }
    if (this.done) return;
    const dec = this.decoder!;
    const base = h.epoch * h.epochChunks + block * n;
    for (let i = 0; i < n; i++) {
      this.stats.chunksAdded++;
      dec.add(base + i, bytes[i]);
    }
    this.events.onProgress?.(dec.progress, dec.L, dec.received);
    if (dec.complete) {
      const bytesOut = dec.result()!;
      const payload = decodePayload(bytesOut);
      if (payload) {
        this.done = true;
        this.events.onDone?.(payload, bytesOut, h);
      } else {
        // A wrong chunk slipped past a block CRC (about 1 in 256 bad blocks) and
        // poisoned the solve. We can't tell which one, so drop everything for this
        // message and decode again from the chunks still to come (the sender loops).
        this.stats.crcFailures++;
        this.decoder = new LTDecoder(h.length, h.msgId);
        this.events.onCrcFail?.(bytesOut, h);
      }
    }
  }

  private onHeader(h: Header): void {
    this.stats.headers++;
    this.confirmed = true;
    if (!this.decoder || !this.header || this.header.msgId !== h.msgId || this.header.length !== h.length) {
      this.decoder = new LTDecoder(h.length, h.msgId);
      this.done = false;
    }
    this.header = h;
    this.events.onHeader?.(h);
  }

  private log(obs: Observation, seq: number | null, marker: number | null, lost: number, kind: FrameLog['kind'], symbols: string): void {
    this.events.onFrame?.({ t: obs.t, seq, marker, lost, kind, symbols, state: this.state });
  }
}

/** Returns the common color if every cell is the same non-null color, else undefined. */
export function uniformColor(cells: (Color | null)[]): Color | undefined {
  if (cells.length === 0 || cells[0] === null) return undefined;
  const c = cells[0];
  for (let i = 1; i < cells.length; i++) if (cells[i] !== c) return undefined;
  return c;
}

/**
 * Turns raw per-capture observations into accepted frames. A frame is accepted
 * when `agree` consecutive captures classify identically and differ from the
 * last accepted frame. Because the marker moves every transmitted frame, two
 * consecutive transmitted frames are never identical.
 */
export class FrameAcceptor {
  private prev: (Color | null)[] | null = null;
  private run = 0;
  private lastAccepted: (Color | null)[] | null = null;
  constructor(public agree = 2) {}

  offer(cells: (Color | null)[], t: number): Observation | null {
    if (this.prev && sameCells(this.prev, cells)) this.run++;
    else this.run = 1;
    this.prev = cells;
    if (this.run < this.agree) return null;
    if (this.lastAccepted && sameCells(this.lastAccepted, cells)) return null;
    this.lastAccepted = cells;
    return { t, cells };
  }

  reset(): void {
    this.prev = null;
    this.run = 0;
    this.lastAccepted = null;
  }
}

export function sameCells(a: (Color | null)[], b: (Color | null)[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
