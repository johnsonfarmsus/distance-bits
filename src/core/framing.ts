import { BitReader, BitWriter } from './bits';
import { crc8 } from './crc';
import type { Config, Fps, PaletteName, PresetName } from './config';
import { FPS_VALUES, PALETTE_NAMES, PRESET_NAMES } from './config';

/*
 * Beacon (32 bits, always sent as 1x1 W/R symbol+separator pairs so any receiver can read it):
 *   sync16 = 0xB5C2 | preset(2) palette(2) fps(2) reserved(2) | crc8 over the 3 preceding bytes
 *
 * Header (56 bits, sent in the session's grid + palette, once per epoch):
 *   sync8 = 0xD3 | msgId(8) | length(16) | epoch(8) | flags(8) | crc8 over the 6 preceding bytes
 */

export const BEACON_SYNC = 0xb5c2;
export const BEACON_BITS = 32;
export const HEADER_SYNC = 0xd3;
export const HEADER_BITS = 56;

export function encodeBeacon(cfg: Config): number[] {
  const w = new BitWriter();
  w.write(BEACON_SYNC, 16);
  const preset = PRESET_NAMES.indexOf(cfg.preset);
  const palette = PALETTE_NAMES.indexOf(cfg.palette);
  const fps = FPS_VALUES.indexOf(cfg.fps);
  w.write((preset << 6) | (palette << 4) | (fps << 2), 8);
  const bytes = w.toBytes();
  w.write(crc8(bytes, 0, 3), 8);
  return w.toBits();
}

export function decodeBeacon(bits: ArrayLike<number | null>): Config | null {
  if (bits.length < BEACON_BITS) return null;
  const r = new BitReader(bits);
  const sync = r.read(16);
  if (sync !== BEACON_SYNC) return null;
  const b2 = r.read(8);
  const crc = r.read(8);
  if (b2 === null || crc === null) return null;
  const bytes = [BEACON_SYNC >> 8, BEACON_SYNC & 0xff, b2];
  if (crc8(bytes) !== crc) return null;
  const preset = PRESET_NAMES[(b2 >> 6) & 3] as PresetName | undefined;
  const palette = PALETTE_NAMES[(b2 >> 4) & 3] as PaletteName | undefined;
  const fps = FPS_VALUES[(b2 >> 2) & 3] as Fps | undefined;
  if (!preset || !palette || !fps) return null;
  return { preset, palette, fps };
}

export interface Header {
  msgId: number;
  length: number;
  epoch: number;
  flags: number;
}

export function encodeHeader(h: Header): number[] {
  const w = new BitWriter();
  w.write(HEADER_SYNC, 8);
  w.write(h.msgId & 0xff, 8);
  w.write(h.length & 0xffff, 16);
  w.write(h.epoch & 0xff, 8);
  w.write(h.flags & 0xff, 8);
  w.write(crc8(w.toBytes(), 0, 6), 8);
  return w.toBits();
}

export function decodeHeader(bits: ArrayLike<number | null>): Header | null {
  if (bits.length < HEADER_BITS) return null;
  const r = new BitReader(bits);
  const sync = r.read(8);
  if (sync !== HEADER_SYNC) return null;
  const msgId = r.read(8);
  const length = r.read(16);
  const epoch = r.read(8);
  const flags = r.read(8);
  const crc = r.read(8);
  if (msgId === null || length === null || epoch === null || flags === null || crc === null) return null;
  const bytes = [HEADER_SYNC, msgId, length >> 8, length & 0xff, epoch, flags];
  if (crc8(bytes) !== crc) return null;
  if (length === 0) return null;
  return { msgId, length, epoch, flags };
}
