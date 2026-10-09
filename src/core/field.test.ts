import { describe, expect, it } from 'vitest';
import { fileURLToPath } from 'node:url';
import { replay } from './replay';

// Real receiver logs from the phones, replayed capture by capture.
const fixture = (name: string) => fileURLToPath(new URL(`../../test-data/${name}`, import.meta.url));

describe('field recordings', () => {
  it('2026-10-08 near/rgbw, 14 Pro receiving at ~50 cm: settings stay put', () => {
    // Before the fix, missed frames flipped the fps guess between 10/15/30 about 25
    // times, and every flip threw away the stream.
    const r = replay(fixture('field-2026-10-08-near-rgbw-50cm.csv'));
    const configs = r.events.filter((e) => e.startsWith('config'));
    expect(configs).toEqual(['config auto near/rgbw/30']);
    expect(r.stats.headers).toBeGreaterThanOrEqual(4);
  });
});
