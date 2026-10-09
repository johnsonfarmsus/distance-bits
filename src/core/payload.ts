import { crc16 } from './crc';

/**
 * Message container carried inside the fountain-coded bytes:
 *   type(1) | crc16 of body(2) | body
 * Body by type:
 *   0 text  : UTF-8
 *   1 file  : nameLen(1) | name (UTF-8) | data
 *   2 image : mimeLen(1) | mime | data   (already compressed by the sender)
 */
export const enum PayloadType {
  Text = 0,
  File = 1,
  Image = 2,
}

export type Payload =
  | { type: PayloadType.Text; text: string }
  | { type: PayloadType.File; name: string; data: Uint8Array }
  | { type: PayloadType.Image; mime: string; data: Uint8Array };

export const MAX_PAYLOAD_BYTES = 65535;

const enc = new TextEncoder();
const dec = new TextDecoder();

function concat(parts: Uint8Array[]): Uint8Array {
  const n = parts.reduce((a, p) => a + p.length, 0);
  const out = new Uint8Array(n);
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

export function encodePayload(p: Payload): Uint8Array {
  let body: Uint8Array;
  switch (p.type) {
    case PayloadType.Text:
      body = enc.encode(p.text);
      break;
    case PayloadType.File: {
      const name = enc.encode(p.name).slice(0, 255);
      body = concat([Uint8Array.of(name.length), name, p.data]);
      break;
    }
    case PayloadType.Image: {
      const mime = enc.encode(p.mime).slice(0, 255);
      body = concat([Uint8Array.of(mime.length), mime, p.data]);
      break;
    }
  }
  const crc = crc16(body);
  const out = concat([Uint8Array.of(p.type, crc >> 8, crc & 0xff), body]);
  if (out.length > MAX_PAYLOAD_BYTES) throw new Error(`payload too large: ${out.length} bytes`);
  return out;
}

export function decodePayload(bytes: Uint8Array): Payload | null {
  if (bytes.length < 3) return null;
  const type = bytes[0];
  const crc = (bytes[1] << 8) | bytes[2];
  const body = bytes.subarray(3);
  if (crc16(body) !== crc) return null;
  switch (type) {
    case PayloadType.Text:
      return { type, text: dec.decode(body) };
    case PayloadType.File: {
      const n = body[0];
      return { type, name: dec.decode(body.subarray(1, 1 + n)), data: body.slice(1 + n) };
    }
    case PayloadType.Image: {
      const n = body[0];
      return { type, mime: dec.decode(body.subarray(1, 1 + n)), data: body.slice(1 + n) };
    }
    default:
      return null;
  }
}
