import { Color } from './colors';

/** RGBA pixel buffer, same shape as canvas ImageData. */
export interface Image {
  data: Uint8ClampedArray;
  width: number;
  height: number;
}

export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export type RGB = [number, number, number];

/**
 * Find the transmitting screen: the largest bright connected blob. Works on a
 * small image (≈160 px wide). Returns null when nothing bright enough stands
 * out (e.g. during a black separator frame) — callers keep the last rect.
 */
export function findScreen(img: Image, minArea = 12): Rect | null {
  const { data, width, height } = img;
  const n = width * height;
  const v = new Uint8Array(n);
  let sum = 0;
  let max = 0;
  for (let i = 0; i < n; i++) {
    const r = data[i * 4], g = data[i * 4 + 1], b = data[i * 4 + 2];
    const m = r > g ? (r > b ? r : b) : g > b ? g : b;
    v[i] = m;
    sum += m;
    if (m > max) max = m;
  }
  const mean = sum / n;
  if (max - mean < 40) return null;
  // Low fraction on purpose: where two saturated colors meet (R|G, R|B, G|B) the
  // blurred edge dips to ~50% of full brightness, and a higher threshold would
  // split one screen into several blobs.
  const thr = mean + 0.25 * (max - mean);
  const label = new Int32Array(n).fill(-1);
  let best: Rect | null = null;
  let bestArea = 0;
  const stack: number[] = [];
  let comp = 0;
  for (let start = 0; start < n; start++) {
    if (v[start] < thr || label[start] >= 0) continue;
    let minX = width, minY = height, maxX = 0, maxY = 0, area = 0;
    stack.push(start);
    label[start] = comp;
    while (stack.length) {
      const p = stack.pop()!;
      const x = p % width, y = (p - x) / width;
      area++;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      const nb = [p - 1, p + 1, p - width, p + width];
      if (x === 0) nb[0] = -1;
      if (x === width - 1) nb[1] = -1;
      for (const q of nb) {
        if (q < 0 || q >= n || label[q] >= 0 || v[q] < thr) continue;
        label[q] = comp;
        stack.push(q);
      }
    }
    if (area > bestArea) {
      bestArea = area;
      best = { x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1 };
    }
    comp++;
  }
  if (!best || bestArea < minArea) return null;
  return best;
}

/**
 * Smooths screen detection over time. The bright-blob bbox of a single frame can
 * miss part of the screen (in Mid the black marker is half the screen), so the
 * tracked rect is the union of recent detections, and it survives frames with no
 * detection (black separators) for `holdMs`.
 */
export class RectTracker {
  private recent: { t: number; r: Rect }[] = [];
  constructor(public windowMs = 400, public holdMs = 1500) {}

  update(found: Rect | null, t: number): Rect | null {
    if (found) this.recent.push({ t, r: found });
    this.recent = this.recent.filter((e) => t - e.t <= this.holdMs);
    if (this.recent.length === 0) return null;
    const win = this.recent.filter((e) => t - e.t <= this.windowMs);
    const use = win.length ? win : [this.recent[this.recent.length - 1]];
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const { r } of use) {
      x0 = Math.min(x0, r.x);
      y0 = Math.min(y0, r.y);
      x1 = Math.max(x1, r.x + r.w);
      y1 = Math.max(y1, r.y + r.h);
    }
    return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
  }

  reset(): void {
    this.recent = [];
  }
}

/** Average RGB of the central region of each grid cell inside rect (raster order). */
export function sampleCells(img: Image, rect: Rect, cols: number, rows: number, inset = 0.25): RGB[] {
  const out: RGB[] = [];
  const cw = rect.w / cols, ch = rect.h / rows;
  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      const x0 = Math.round(rect.x + c * cw + cw * inset);
      const x1 = Math.max(x0 + 1, Math.round(rect.x + (c + 1) * cw - cw * inset));
      const y0 = Math.round(rect.y + r * ch + ch * inset);
      const y1 = Math.max(y0 + 1, Math.round(rect.y + (r + 1) * ch - ch * inset));
      let sr = 0, sg = 0, sb = 0, cnt = 0;
      for (let y = y0; y < y1; y++) {
        if (y < 0 || y >= img.height) continue;
        for (let x = x0; x < x1; x++) {
          if (x < 0 || x >= img.width) continue;
          const i = (y * img.width + x) * 4;
          sr += img.data[i];
          sg += img.data[i + 1];
          sb += img.data[i + 2];
          cnt++;
        }
      }
      out.push(cnt ? [sr / cnt, sg / cnt, sb / cnt] : [0, 0, 0]);
    }
  }
  return out;
}

export interface Calibration {
  /** Brightest channel value seen for a lit cell. */
  white: number;
  /** Brightest channel value seen for a black cell. */
  black: number;
}

/** Tracks black and white levels with slow decay so exposure drift is followed. */
export class Calibrator {
  calib: Calibration = { white: 200, black: 20 };
  update(samples: RGB[]): void {
    let hi = 0, lo = 255;
    for (const [r, g, b] of samples) {
      const m = Math.max(r, g, b);
      if (m > hi) hi = m;
      if (m < lo) lo = m;
    }
    this.calib.white = Math.max(hi, this.calib.white * 0.97);
    this.calib.black = Math.min(lo, this.calib.black * 1.03 + 1);
    if (this.calib.white - this.calib.black < 40) this.calib.white = this.calib.black + 40;
  }
}

export interface ClassifyOptions {
  /** Fraction of the black→white span below which a cell is black. */
  blackFrac: number;
  /** Max normalized-channel share below which a cell counts as white. */
  whiteMaxShare: number;
}

export const DEFAULT_CLASSIFY: ClassifyOptions = { blackFrac: 0.35, whiteMaxShare: 0.45 };

/**
 * Classify one cell. Darkness uses the brightest channel (not luma) so a dim
 * blue cell is not mistaken for black. Hue uses channel shares so exposure
 * doesn't matter.
 */
export function classifyCell(rgb: RGB, calib: Calibration, opt: ClassifyOptions = DEFAULT_CLASSIFY): Color | null {
  const [r, g, b] = rgb;
  const m = Math.max(r, g, b);
  if (m < calib.black + opt.blackFrac * (calib.white - calib.black)) return Color.K;
  const br = Math.max(0, r - calib.black), bg = Math.max(0, g - calib.black), bb = Math.max(0, b - calib.black);
  const s = br + bg + bb;
  if (s <= 0) return null;
  const nr = br / s, ng = bg / s, nb = bb / s;
  const top = Math.max(nr, ng, nb);
  if (top < opt.whiteMaxShare) return Color.W;
  if (top === nr) return Color.R;
  if (top === ng) return Color.G;
  return Color.B;
}

export function classifyCells(samples: RGB[], calib: Calibration, opt?: ClassifyOptions): (Color | null)[] {
  return samples.map((s) => classifyCell(s, calib, opt));
}

// ---- helpers used by the simulator and tests ---------------------------------

export function boxBlur(img: Image, radius: number): Image {
  if (radius <= 0) return img;
  const { width, height } = img;
  const src = img.data;
  const tmp = new Float32Array(width * height * 4);
  const out = new Uint8ClampedArray(width * height * 4);
  const span = 2 * radius + 1;
  for (let y = 0; y < height; y++) {
    for (let ch = 0; ch < 4; ch++) {
      let acc = 0;
      for (let x = -radius; x <= radius; x++) acc += src[(y * width + clamp(x, width)) * 4 + ch];
      for (let x = 0; x < width; x++) {
        tmp[(y * width + x) * 4 + ch] = acc / span;
        acc += src[(y * width + clamp(x + radius + 1, width)) * 4 + ch] - src[(y * width + clamp(x - radius, width)) * 4 + ch];
      }
    }
  }
  for (let x = 0; x < width; x++) {
    for (let ch = 0; ch < 4; ch++) {
      let acc = 0;
      for (let y = -radius; y <= radius; y++) acc += tmp[(clamp(y, height) * width + x) * 4 + ch];
      for (let y = 0; y < height; y++) {
        out[(y * width + x) * 4 + ch] = acc / span;
        acc += tmp[(clamp(y + radius + 1, height) * width + x) * 4 + ch] - tmp[(clamp(y - radius, height) * width + x) * 4 + ch];
      }
    }
  }
  return { data: out, width, height };
}

function clamp(i: number, n: number): number {
  return i < 0 ? 0 : i >= n ? n - 1 : i;
}

export function addNoise(img: Image, amplitude: number, rand: () => number = Math.random): Image {
  if (amplitude <= 0) return img;
  const out = new Uint8ClampedArray(img.data);
  for (let i = 0; i < out.length; i++) {
    if ((i & 3) === 3) continue;
    out[i] = out[i] + (rand() * 2 - 1) * amplitude;
  }
  return { data: out, width: img.width, height: img.height };
}

/** Paint a grid of colors into a rect of an RGBA image (test/simulator helper). */
export function paintCells(img: Image, rect: Rect, cols: number, rows: number, cells: Color[], rgbOf: (c: Color) => RGB): void {
  const cw = rect.w / cols, ch = rect.h / rows;
  for (let y = 0; y < rect.h; y++) {
    const r = Math.min(rows - 1, Math.floor(y / ch));
    for (let x = 0; x < rect.w; x++) {
      const c = Math.min(cols - 1, Math.floor(x / cw));
      const [cr, cg, cb] = rgbOf(cells[r * cols + c]);
      const i = ((rect.y + y) * img.width + rect.x + x) * 4;
      img.data[i] = cr;
      img.data[i + 1] = cg;
      img.data[i + 2] = cb;
      img.data[i + 3] = 255;
    }
  }
}

export function solidImage(width: number, height: number, rgb: RGB): Image {
  const data = new Uint8ClampedArray(width * height * 4);
  for (let i = 0; i < width * height; i++) {
    data[i * 4] = rgb[0];
    data[i * 4 + 1] = rgb[1];
    data[i * 4 + 2] = rgb[2];
    data[i * 4 + 3] = 255;
  }
  return { data, width, height };
}
