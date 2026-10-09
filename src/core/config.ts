import { Color } from './colors';

export type PresetName = 'near' | 'mid' | 'far';
export type PaletteName = 'wr' | 'rgw' | 'rgbw';
export type Fps = 30 | 15 | 10;

export interface Config {
  preset: PresetName;
  palette: PaletteName;
  fps: Fps;
}

export interface PresetDef {
  cols: number;
  rows: number;
  /** Marker period: how many frames before the marker position repeats. */
  markerPeriod: number;
  /** Payload symbols carried per frame (0.5 for Far, where every other frame is a separator). */
  symbolsPerFrame: number;
  defaultFps: Fps;
  defaultPalette: PaletteName;
  /** How many times the header is repeated back-to-back; the receiver merges copies to fill lost symbols. */
  headerRepeat: number;
}

export const PRESETS: Record<PresetName, PresetDef> = {
  near: { cols: 2, rows: 4, markerPeriod: 8, symbolsPerFrame: 7, defaultFps: 30, defaultPalette: 'rgbw', headerRepeat: 2 },
  mid: { cols: 1, rows: 2, markerPeriod: 2, symbolsPerFrame: 1, defaultFps: 30, defaultPalette: 'rgbw', headerRepeat: 3 },
  far: { cols: 1, rows: 1, markerPeriod: 2, symbolsPerFrame: 0.5, defaultFps: 15, defaultPalette: 'wr', headerRepeat: 3 },
};

/** Payload palettes: symbol index -> physical color. Black is never a payload color. */
export const PALETTES: Record<PaletteName, Color[]> = {
  wr: [Color.W, Color.R],
  rgw: [Color.R, Color.G, Color.W],
  rgbw: [Color.R, Color.G, Color.B, Color.W],
};

export const PRESET_NAMES: PresetName[] = ['near', 'mid', 'far'];
export const PALETTE_NAMES: PaletteName[] = ['wr', 'rgw', 'rgbw'];
export const FPS_VALUES: Fps[] = [30, 15, 10];

/** Symbols per packing group. Fixed at 7 so a Near frame is exactly one group. */
export const GROUP_SYMBOLS = 7;
/** Fountain chunks per epoch; a header precedes every epoch. */
export const EPOCH_CHUNKS = 64;
export const EPOCH_BITS = EPOCH_CHUNKS * 8;
/** A beacon precedes every Nth epoch (the first one always). */
export const DEFAULT_BEACON_EVERY = 4;

export function defaultConfig(preset: PresetName): Config {
  const p = PRESETS[preset];
  return { preset, palette: p.defaultPalette, fps: p.defaultFps };
}

export function paletteSize(palette: PaletteName): number {
  return PALETTES[palette].length;
}

/** Inverse palette lookup: physical color -> symbol index, or -1 if not in the palette. */
export function symbolOf(palette: PaletteName, color: Color): number {
  return PALETTES[palette].indexOf(color);
}

export function framePeriodMs(fps: Fps): number {
  return 1000 / fps;
}
