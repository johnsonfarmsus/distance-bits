import { Color } from './colors';
import type { Config } from './config';
import { DEFAULT_BEACON_EVERY, EPOCH_CHUNKS, GROUP_SYMBOLS, PALETTES, PRESETS } from './config';
import { LTEncoder } from './fountain';
import { encodeBeacon, encodeHeader } from './framing';
import { bitsToSymbols } from './packing';
import { bytesToBits } from './bits';

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
  private gen: Generator<Frame, never, void>;
  private encoder: LTEncoder;
  private seq = 0;
  private k: number;

  constructor(public readonly cfg: Config, public readonly payload: Uint8Array, opts: TransmitterOptions = {}) {
    if (payload.length === 0 || payload.length > 0xffff) throw new Error('payload must be 1..65535 bytes');
    this.msgId = opts.msgId ?? Math.floor(Math.random() * 256);
    this.beaconEvery = Math.max(1, opts.beaconEvery ?? DEFAULT_BEACON_EVERY);
    this.k = PALETTES[cfg.palette].length;
    this.encoder = new LTEncoder(payload, this.msgId);
    this.gen = this.run();
  }

  next(): Frame {
    return this.gen.next().value;
  }

  /** Frames per epoch (header + chunks), for progress/time estimates. */
  framesPerEpoch(): number {
    const p = PRESETS[this.cfg.preset];
    const headerSyms = bitsToSymbols(encodeHeader({ msgId: 0, length: 1, epoch: 0, flags: 0 }), this.k).length * p.headerRepeat;
    const epochSyms = bitsToSymbols(new Array(EPOCH_CHUNKS * 8).fill(0), this.k).length;
    return (headerSyms + epochSyms) / p.symbolsPerFrame;
  }

  private *run(): Generator<Frame, never, void> {
    for (let epoch = 0; ; epoch++) {
      if (epoch % this.beaconEvery === 0) yield* this.blobBits(encodeBeacon(this.cfg), 'beacon', epoch);
      const header = encodeHeader({ msgId: this.msgId, length: this.payload.length, epoch: epoch & 0xff, flags: 0 });
      const headerSyms = bitsToSymbols(header, this.k);
      for (let r = 0; r < PRESETS[this.cfg.preset].headerRepeat; r++) yield* this.symbols(headerSyms, 'header', epoch);
      const bytes = new Uint8Array(EPOCH_CHUNKS);
      for (let i = 0; i < EPOCH_CHUNKS; i++) bytes[i] = this.encoder.chunk(epoch * EPOCH_CHUNKS + i);
      yield* this.symbols(bitsToSymbols(bytesToBits(bytes), this.k), 'payload', epoch);
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
