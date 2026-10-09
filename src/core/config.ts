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
  /**
   * Chunks per CRC-checked block. One lost or misread symbol drops the whole block,
   * so presets that carry few bits per frame use small blocks.
   */
  blockChunks: number;
}

export const PRESETS: Record<PresetName, PresetDef> = {
  near: { cols: 2, rows: 4, markerPeriod: 8, symbolsPerFrame: 7, defaultFps: 30, defaultPalette: 'rgbw', headerRepeat: 2, blockChunks: 4 },
  mid: { cols: 1, rows: 2, markerPeriod: 2, symbolsPerFrame: 1, defaultFps: 30, defaultPalette: 'rgbw', headerRepeat: 3, blockChunks: 2 },
  far: { cols: 1, rows: 1, markerPeriod: 2, symbolsPerFrame: 0.5, defaultFps: 15, defaultPalette: 'wr', headerRepeat: 2, blockChunks: 2 },
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
/**
 * Chunks are sent in blocks (PresetDef.blockChunks per block), each followed by a
 * CRC-8. A block that fails its CRC (a misread colour) or has a missing symbol is
 * dropped, so the fountain decoder only ever sees missing chunks, never wrong ones.
 */
export function blockBits(blockChunks: number): number {
  return blockChunks * 8 + 8;
}
/** Allowed epoch lengths in chunks (a header precedes every epoch); coded in 2 header-flag bits. */
export const EPOCH_SIZES = [8, 16, 32, 64] as const;
export type EpochSize = (typeof EPOCH_SIZES)[number];

/**
 * Epoch length for an L-byte payload: about 1.5×L so one epoch covers the
 * systematic pass plus some repair chunks, capped at 64. Short messages get short
 * epochs, so a receiver that joins late or loses lock waits less for a header.
 */
export function epochChunksFor(L: number): EpochSize {
  for (const e of EPOCH_SIZES) if (e >= Math.ceil(L * 1.5)) return e;
  return 64;
}

export function epochBits(epochChunks: number, blockChunks: number): number {
  return (epochChunks / blockChunks) * blockBits(blockChunks);
}
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
