// Writes app/test/golden.json: frame streams, PRNG output and fountain chunks that
// the Dart port (app/lib/core) must reproduce exactly. Run after any protocol change:
//   GEN_GOLDEN=1 npx vitest run src/core/golden.gen.test.ts
import { it } from 'vitest';
import { writeFileSync } from 'node:fs';
import { PALETTE_NAMES, PRESET_NAMES, defaultConfig } from './config';
import { Transmitter } from './transmitter';
import { encodePayload, PayloadType } from './payload';
import { LTEncoder } from './fountain';
import { Prng, chunkSeed } from './prng';

it.skipIf(!process.env.GEN_GOLDEN)('generate golden vectors for the Dart port', () => {
  const texts = ['hi', 'Meet at the north gate at 7. Bring the long lens.', 'ünïcødé ✓ ' + 'x'.repeat(120)];
  const streams: unknown[] = [];
  for (const preset of PRESET_NAMES) for (const palette of PALETTE_NAMES) for (const text of texts) {
    const cfg = { ...defaultConfig(preset), palette };
    const tx = new Transmitter(cfg, encodePayload({ type: PayloadType.Text, text }), { msgId: 77 });
    const frames: string[] = [];
    for (let i = 0; i < 700; i++) {
      const f = tx.next();
      frames.push(`${f.layout[0]}${f.segment[0]}${f.epoch}:${f.cells.join('')}`);
    }
    streams.push({ preset, palette, fps: cfg.fps, text, epochChunks: tx.epochChunks, framesPerEpoch: tx.framesPerEpoch(), frames });
  }
  const prng: number[] = [];
  const r = new Prng(12345);
  for (let i = 0; i < 50; i++) prng.push(r.next());
  const seeds = [[0, 0], [77, 5], [255, 123456], [3, 2 ** 31 + 7]].map(([m, c]) => chunkSeed(m, c));
  const data = Uint8Array.from({ length: 300 }, (_, i) => (i * 37 + 11) & 0xff);
  const fountain: Record<string, number[]> = {};
  for (const L of [1, 2, 5, 50, 300]) {
    const enc = new LTEncoder(data.slice(0, L), 42);
    fountain[L] = Array.from({ length: 400 }, (_, c) => enc.chunk(c));
  }
  writeFileSync(new URL('../../app/test/golden.json', import.meta.url), JSON.stringify({ streams, prng, seeds, fountain }));
});
