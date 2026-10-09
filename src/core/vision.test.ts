import { describe, expect, it } from 'vitest';
import { COLOR_RGB, Color } from './colors';
import { Calibrator, RectTracker, addNoise, boxBlur, classifyCells, findScreen, paintCells, sampleCells, solidImage } from './vision';
import { Prng } from './prng';

function scene(cells: Color[], cols: number, rows: number, blur: number, noise = 0) {
  const img = solidImage(120, 160, [25, 22, 20]);
  const rect = { x: 40, y: 30, w: 40, h: 80 };
  paintCells(img, rect, cols, rows, cells, (c) => COLOR_RGB[c]);
  const rng = new Prng(4);
  return { img: addNoise(boxBlur(img, blur), noise, () => rng.next()), rect };
}

describe('vision', () => {
  it('finds the screen and classifies a Near frame through blur and noise', () => {
    const cells = [Color.K, Color.R, Color.G, Color.B, Color.W, Color.R, Color.B, Color.W];
    const { img, rect } = scene(cells, 2, 4, 2, 12);
    const found = findScreen(img)!;
    expect(found).not.toBeNull();
    expect(Math.abs(found.x - rect.x)).toBeLessThanOrEqual(3);
    expect(Math.abs(found.w - rect.w)).toBeLessThanOrEqual(6);
    const samples = sampleCells(img, found, 2, 4);
    const cal = new Calibrator();
    cal.update(samples);
    cal.update(samples);
    expect(classifyCells(samples, cal.calib)).toEqual(cells);
  });

  it('returns null for a black separator frame', () => {
    const { img } = scene([Color.K], 1, 1, 1);
    expect(findScreen(img)).toBeNull();
  });

  it('classifies a uniform frame as uniform', () => {
    const { img } = scene([Color.R], 1, 1, 1);
    const found = findScreen(img)!;
    const samples = sampleCells(img, found, 2, 4);
    const cal = new Calibrator();
    cal.calib = { white: 255, black: 25 };
    expect(classifyCells(samples, cal.calib)).toEqual(new Array(8).fill(Color.R));
  });

  it('RectTracker unions recent detections and holds through gaps', () => {
    const tr = new RectTracker(400, 1500);
    expect(tr.update({ x: 10, y: 10, w: 20, h: 20 }, 0)).toEqual({ x: 10, y: 10, w: 20, h: 20 });
    expect(tr.update({ x: 10, y: 30, w: 20, h: 20 }, 33)).toEqual({ x: 10, y: 10, w: 20, h: 40 });
    expect(tr.update(null, 500)).toEqual({ x: 10, y: 30, w: 20, h: 20 });
    expect(tr.update(null, 3000)).toBeNull();
  });
});
