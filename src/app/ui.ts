import { FPS_VALUES, PALETTE_NAMES, PRESET_NAMES, type Config, type Fps, type PaletteName, type PresetName, defaultConfig } from '../core';

export function h<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs: Record<string, string | number | boolean | ((e: Event) => void)> = {},
  ...children: (Node | string | null | undefined)[]
): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (typeof v === 'function') el.addEventListener(k, v);
    else if (k === 'class') el.className = String(v);
    else if (k in el && typeof v !== 'boolean') (el as unknown as Record<string, unknown>)[k] = v;
    else if (v === true) el.setAttribute(k, '');
    else if (v !== false) el.setAttribute(k, String(v));
  }
  for (const c of children) if (c != null) el.append(c);
  return el;
}

export function select<T extends string | number>(
  label: string,
  options: { value: T; label: string }[],
  value: T,
  onChange: (v: T) => void,
): { el: HTMLLabelElement; set(v: T): void; get(): T } {
  const sel = h('select') as HTMLSelectElement;
  for (const o of options) sel.append(h('option', { value: String(o.value) }, o.label));
  sel.value = String(value);
  sel.addEventListener('change', () => onChange(parse(sel.value)));
  const parse = (s: string): T => (typeof value === 'number' ? (Number(s) as T) : (s as T));
  return {
    el: h('label', {}, label, sel),
    set: (v) => (sel.value = String(v)),
    get: () => parse(sel.value),
  };
}

const PALETTE_LABELS: Record<PaletteName, string> = {
  wr: 'mode 0 · W/R (2 colors)',
  rgw: 'mode 1a · R/G/W (blue off)',
  rgbw: 'mode 1b · R/G/B/W (blue on)',
};

const PRESET_LABELS: Record<PresetName, string> = {
  near: 'Near · 2×4 grid · ≤12 m',
  mid: 'Mid · 1×2 · 12–25 m',
  far: 'Far · 1×1 · 25–50 m',
};

/** Preset / palette / fps selectors bound to a Config. */
export function configControls(initial: Config, onChange: (cfg: Config) => void) {
  let cfg = { ...initial };
  const preset = select<PresetName>('Range preset', PRESET_NAMES.map((p) => ({ value: p, label: PRESET_LABELS[p] })), cfg.preset, (v) => {
    cfg = defaultConfig(v);
    palette.set(cfg.palette);
    fps.set(cfg.fps);
    onChange(cfg);
  });
  const palette = select<PaletteName>('Palette', PALETTE_NAMES.map((p) => ({ value: p, label: PALETTE_LABELS[p] })), cfg.palette, (v) => {
    cfg = { ...cfg, palette: v };
    onChange(cfg);
  });
  const fps = select<Fps>('TX frame rate', FPS_VALUES.map((f) => ({ value: f, label: `${f} fps` })), cfg.fps, (v) => {
    cfg = { ...cfg, fps: v };
    onChange(cfg);
  });
  return { el: h('div', { class: 'row' }, preset.el, palette.el, fps.el), get: () => cfg, set(c: Config) { cfg = { ...c }; preset.set(c.preset); palette.set(c.palette); fps.set(c.fps); } };
}

export function describeConfig(cfg: Config): string {
  return `${cfg.preset} · ${cfg.palette} · ${cfg.fps} fps`;
}

export function fmtBytes(n: number): string {
  return n < 1024 ? `${n} B` : `${(n / 1024).toFixed(1)} KB`;
}

export function fmtSeconds(s: number): string {
  if (!isFinite(s)) return '—';
  if (s < 90) return `${Math.round(s)} s`;
  return `${Math.floor(s / 60)} min ${Math.round(s % 60)} s`;
}

export function download(name: string, blob: Blob): void {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 5000);
}

/** Blob from a Uint8Array without TS complaining about SharedArrayBuffer. */
export function blobOf(bytes: Uint8Array, type = 'application/octet-stream'): Blob {
  const copy = new Uint8Array(bytes.length);
  copy.set(bytes);
  return new Blob([copy.buffer as ArrayBuffer], { type });
}
