/** CRC-8 (poly 0x07, init 0x00). Used on headers and the beacon. */
export function crc8(bytes: ArrayLike<number>, start = 0, end = bytes.length): number {
  let crc = 0;
  for (let i = start; i < end; i++) {
    crc ^= bytes[i] & 0xff;
    for (let b = 0; b < 8; b++) {
      crc = crc & 0x80 ? ((crc << 1) ^ 0x07) & 0xff : (crc << 1) & 0xff;
    }
  }
  return crc;
}

/** CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF). Used on the plaintext. */
export function crc16(bytes: ArrayLike<number>): number {
  let crc = 0xffff;
  for (let i = 0; i < bytes.length; i++) {
    crc ^= (bytes[i] & 0xff) << 8;
    for (let b = 0; b < 8; b++) {
      crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
    }
  }
  return crc;
}
