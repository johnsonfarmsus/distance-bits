import { describe, expect, it } from 'vitest';
import { Color } from './colors';
import { type Config, PALETTE_NAMES, PALETTES, PRESET_NAMES, PRESETS, defaultConfig, framePeriodMs } from './config';
import { Prng } from './prng';
import { Receiver, FrameAcceptor } from './receiver';
import { Transmitter, type Frame } from './transmitter';
import { decodePayload, encodePayload, PayloadType } from './payload';

/** Expand a frame into the receiver's sampling grid (what the vision layer would produce). */
function cellsFor(frame: Frame, cfg: Config): Color[] {
  const p = PRESETS[cfg.preset];
  const n = p.cols * p.rows;
  if (frame.layout === 'blob') return new Array(n).fill(frame.cells[0]);
  return frame.cells;
}

interface RunOpts {
  loss?: number;
  seed?: number;
  manual?: boolean;
  skipFrames?: number;
  maxFrames?: number;
  jitterMs?: number;
  /** Rewrite a frame's cells before the receiver sees it (simulates misread colours). */
  corrupt?: (f: Frame, cells: Color[]) => Color[];
}

function run(cfg: Config, text: string, o: RunOpts = {}) {
  const payload = encodePayload({ type: PayloadType.Text, text });
  const tx = new Transmitter(cfg, payload, { msgId: 123 });
  let doneBytes: Uint8Array | null = null;
  const rx = new Receiver({ onDone: (_p, bytes) => (doneBytes = bytes) }, o.manual ? cfg : undefined);
  const rng = new Prng(o.seed ?? 1);
  const period = framePeriodMs(cfg.fps);
  const max = o.maxFrames ?? 20000;
  let frames = 0;
  for (let i = 0; i < max && !doneBytes; i++) {
    const f = tx.next();
    frames++;
    if (i < (o.skipFrames ?? 0)) continue;
    if (o.loss && rng.next() < o.loss) continue;
    const t = f.seq * period + (o.jitterMs ? (rng.next() * 2 - 1) * o.jitterMs : 0);
    const cells = cellsFor(f, cfg);
    rx.observe({ t, cells: o.corrupt ? o.corrupt(f, cells) : cells });
  }
  return { doneBytes: doneBytes as Uint8Array | null, frames, rx, payload };
}

describe('end to end', () => {
  const text = 'Meet at the north gate at 7. Bring the long lens.';

  for (const preset of PRESET_NAMES) {
    for (const palette of PALETTE_NAMES) {
      it(`${preset}/${palette}: lossless, auto-config from beacon`, () => {
        const cfg = { ...defaultConfig(preset), palette };
        const r = run(cfg, text);
        expect(r.doneBytes).toEqual(r.payload);
        expect(r.rx.config).toEqual(cfg);
        expect(r.rx.stats.beacons).toBeGreaterThan(0);
      });
    }
  }

  it('near/rgbw: 15% frame loss with timing jitter', () => {
    const cfg = defaultConfig('near');
    const r = run(cfg, text, { loss: 0.15, jitterMs: 8, seed: 3 });
    expect(r.doneBytes).toEqual(r.payload);
    expect(r.rx.stats.lostFrames).toBeGreaterThan(0);
  });

  it('mid/rgbw: 10% frame loss', () => {
    const cfg = defaultConfig('mid');
    const r = run(cfg, 'short msg', { loss: 0.1, seed: 5, jitterMs: 6 });
    expect(r.doneBytes).toEqual(r.payload);
  });

  it('far/wr: 10% frame loss at 15 fps', () => {
    const cfg = defaultConfig('far');
    const r = run(cfg, 'ok?', { loss: 0.1, seed: 8, jitterMs: 10 });
    expect(r.doneBytes).toEqual(r.payload);
  });

  it('receiver joining mid-stream with manual config still decodes', () => {
    const cfg = defaultConfig('near');
    const r = run(cfg, text, { manual: true, skipFrames: 37 });
    expect(r.doneBytes).toEqual(r.payload);
  });

  it('receiver joining mid-stream with no config waits for the next beacon', () => {
    const cfg = { ...defaultConfig('near'), palette: 'rgw' as const };
    const r = run(cfg, text, { skipFrames: 100 });
    expect(r.doneBytes).toEqual(r.payload);
  });

  it('decoded bytes parse back into the payload', () => {
    const cfg = defaultConfig('near');
    const r = run(cfg, text);
    expect(decodePayload(r.doneBytes!)).toEqual({ type: PayloadType.Text, text });
  });

  it('lossless near/rgbw finishes in about one pass', () => {
    const cfg = defaultConfig('near');
    const r = run(cfg, text);
    // payload 52 bytes -> 1 epoch (64 chunks) + beacon + header ≈ 64 + 4 + 37 frames
    expect(r.frames).toBeLessThan(130);
  });

  it('an 8 KB payload decodes with 5% loss', () => {
    const cfg = defaultConfig('near');
    const big = 'x'.repeat(8000);
    const r = run(cfg, big, { loss: 0.05, seed: 11, maxFrames: 200000 });
    expect(r.doneBytes).toEqual(r.payload);
  });
});

describe('misread colours', () => {
  const text = 'Meet at the north gate at 7. Bring the long lens.';

  it('a systematic misread (red seen as green) in one epoch is caught by block CRCs', () => {
    const cfg = defaultConfig('near');
    const corrupt = (f: Frame, cells: Color[]) =>
      f.segment === 'payload' && f.epoch === 0 ? cells.map((c) => (c === Color.R ? Color.G : c)) : cells;
    const r = run(cfg, text, { corrupt, maxFrames: 5000 });
    expect(r.rx.stats.blocksBad).toBeGreaterThan(0);
    expect(r.doneBytes).toEqual(r.payload);
  });

  for (const [preset, rate] of [['near', 0.02], ['mid', 0.02], ['far', 0.02]] as const) {
    it(`${preset}: ${rate * 100}% random colour errors never produce a wrong message`, () => {
      for (const seed of [1, 2, 3, 4]) {
        const cfg = defaultConfig(preset);
        const pal = PALETTES[cfg.palette];
        const rng = new Prng(1000 + seed);
        const corrupt = (f: Frame, cells: Color[]) =>
          f.segment === 'beacon'
            ? cells
            : cells.map((c) => (c !== Color.K && rng.next() < rate ? pal[(pal.indexOf(c) + 1 + rng.int(pal.length - 1)) % pal.length] : c));
        const r = run(cfg, preset === 'far' ? 'ok?' : text, { corrupt, seed, maxFrames: 60000 });
        expect(r.doneBytes).toEqual(r.payload);
      }
    });
  }
});

describe('short messages', () => {
  it('"hi" at Far (W/R, 15 fps) decodes in under 30 s of frames', () => {
    const cfg = defaultConfig('far');
    const r = run(cfg, 'hi');
    expect(r.doneBytes).toEqual(r.payload);
    expect(r.frames / cfg.fps).toBeLessThan(30);
  });

  it('a receiver that joins mid-way waits less than one long epoch for a short message', () => {
    const cfg = defaultConfig('mid');
    const tx = new Transmitter(cfg, encodePayload({ type: PayloadType.Text, text: 'hi' }));
    expect(tx.epochChunks).toBe(8);
  });
});

describe('FrameAcceptor', () => {
  it('accepts a frame after two agreeing captures and not again until it changes', () => {
    const a = new FrameAcceptor(2);
    const f1 = [Color.K, Color.W, Color.R];
    const f2 = [Color.W, Color.K, Color.R];
    expect(a.offer(f1, 0)).toBeNull();
    expect(a.offer(f1, 16)).not.toBeNull();
    expect(a.offer(f1, 33)).toBeNull();
    expect(a.offer(f2, 50)).toBeNull();
    expect(a.offer(f2, 66)).not.toBeNull();
  });
});
