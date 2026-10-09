import { Color } from './colors';
import type { Config } from './config';
import { DEFAULT_BEACON_EVERY, GROUP_SYMBOLS, PALETTES, PRESETS, epochBits, epochChunksFor, type EpochSize } from './config';
import { LTEncoder } from './fountain';
import { encodeBeacon, encodeBlock, encodeHeader } from './framing';
import { bitsToSymbols } from './packing';

/** One screen refresh worth of content. */
export interface Frame {
  /** Monotonic frame counter; the marker position is derived from it. */
  seq: number;
  /** 'grid' paints cols×rows cells; 'blob' paints the whole screen one color. */
  layout: 'grid' | 'blob';
  /** Physical colors, raster order (row-major) for grid; a single entry for blob. */
  cells: Color[];
  /** What this frame belongs to, for the UI. */
  segment: 'beacon' | 'header' | 'payload';
  epoch: number;
}

export interface TransmitterOptions {
  msgId?: number;
  beaconEvery?: number;
  /** Header flag bits other than the epoch size (e.g. FLAG_ENCRYPTED). */
  flags?: number;
}

/**
 * Turns a payload into an endless sequence of frames:
 *   [beacon] header epoch-0-chunks | header epoch-1-chunks | ... (beacon every Nth epoch)
 * The transmitter never stops on its own; the app stops it when the uplink says DONE
 * or the user cancels.
 */
export class Transmitter {
  readonly msgId: number;
  readonly beaconEvery: number;
  readonly flags: number;
  private gen: Generator<Frame, never, void>;
  private encoder: LTEncoder;
  private seq = 0;
  private k: number;
  readonly epochChunks: EpochSize;

  constructor(public readonly cfg: Config, public readonly payload: Uint8Array, opts: TransmitterOptions = {}) {
    if (payload.length === 0 || payload.length > 0xffff) throw new Error('payload must be 1..65535 bytes');
    this.msgId = opts.msgId ?? Math.floor(Math.random() * 256);
    this.beaconEvery = Math.max(1, opts.beaconEvery ?? DEFAULT_BEACON_EVERY);
    this.flags = opts.flags ?? 0;
    this.k = PALETTES[cfg.palette].length;
    this.encoder = new LTEncoder(payload, this.msgId);
    this.epochChunks = epochChunksFor(payload.length);
    this.gen = this.run();
  }

  next(): Frame {
    return this.gen.next().value;
  }

  /** Frames per epoch (header copies + blocks), for progress/time estimates. */
  framesPerEpoch(): number {
    const p = PRESETS[this.cfg.preset];
    const headerSyms = bitsToSymbols(encodeHeader({ msgId: 0, length: 1, epoch: 0, epochChunks: this.epochChunks, flags: 0 }), this.k).length * p.headerRepeat;
    const epochSyms = bitsToSymbols(new Array(epochBits(this.epochChunks, p.blockChunks)).fill(0), this.k).length;
    return (headerSyms + epochSyms) / p.symbolsPerFrame;
  }

  private *run(): Generator<Frame, never, void> {
    const E = this.epochChunks;
    const n = PRESETS[this.cfg.preset].blockChunks;
    for (let epoch = 0; ; epoch++) {
      if (epoch % this.beaconEvery === 0) yield* this.blobBits(encodeBeacon(this.cfg), 'beacon', epoch);
      // The header carries the epoch mod 256, so chunk indices wrap with it: after
      // 256 epochs the same chunks repeat, which the decoder treats as duplicates.
      const e8 = epoch & 0xff;
      const header = encodeHeader({ msgId: this.msgId, length: this.payload.length, epoch: e8, epochChunks: E, flags: this.flags });
      const headerSyms = bitsToSymbols(header, this.k);
      for (let r = 0; r < PRESETS[this.cfg.preset].headerRepeat; r++) yield* this.symbols(headerSyms, 'header', epoch);
      const bits: number[] = [];
      for (let b = 0; b < E / n; b++) {
        const bytes = new Array<number>(n);
        for (let i = 0; i < n; i++) bytes[i] = this.encoder.chunk(e8 * E + b * n + i);
        bits.push(...encodeBlock(this.msgId, e8, b, bytes));
      }
      yield* this.symbols(bitsToSymbols(bits, this.k), 'payload', epoch);
    }
  }

  /** Beacon bits as W/R blob frames, each followed by a black separator frame. */
  private *blobBits(bits: number[], segment: Frame['segment'], epoch: number): Generator<Frame, void, void> {
    for (const b of bits) {
      yield this.frame('blob', [b ? Color.R : Color.W], segment, epoch);
      yield this.frame('blob', [Color.K], segment, epoch);
    }
  }

  /** Payload symbols laid out per preset, with the walking black marker. */
  private *symbols(syms: number[], segment: Frame['segment'], epoch: number): Generator<Frame, void, void> {
    const cfg = this.cfg;
    const pal = PALETTES[cfg.palette];
    const p = PRESETS[cfg.preset];
    if (cfg.preset === 'near') {
      for (let g = 0; g < syms.length; g += GROUP_SYMBOLS) {
        const cells = new Array<Color>(p.cols * p.rows);
        const marker = this.seq % p.markerPeriod;
        let s = g;
        for (let i = 0; i < cells.length; i++) cells[i] = i === marker ? Color.K : pal[syms[s++]];
        yield this.frame('grid', cells, segment, epoch);
      }
    } else if (cfg.preset === 'mid') {
      for (const sym of syms) {
        const marker = this.seq % 2;
        const cells = marker === 0 ? [Color.K, pal[sym]] : [pal[sym], Color.K];
        yield this.frame('grid', cells, segment, epoch);
      }
    } else {
      for (const sym of syms) {
        yield this.frame('blob', [pal[sym]], segment, epoch);
        yield this.frame('blob', [Color.K], segment, epoch);
      }
    }
  }

  private frame(layout: Frame['layout'], cells: Color[], segment: Frame['segment'], epoch: number): Frame {
    return { seq: this.seq++, layout, cells, segment, epoch };
  }
}
