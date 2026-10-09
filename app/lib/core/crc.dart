/// CRC-8 (poly 0x07, init 0x00). Headers, the beacon and blocks.
int crc8(List<int> bytes, [int start = 0, int? end]) {
  var crc = 0;
  final e = end ?? bytes.length;
  for (var i = start; i < e; i++) {
    crc ^= bytes[i] & 0xff;
    for (var b = 0; b < 8; b++) {
      crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x07) & 0xff : (crc << 1) & 0xff;
    }
  }
  return crc;
}

/// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF). The payload container.
int crc16(List<int> bytes) {
  var crc = 0xffff;
  for (final v in bytes) {
    crc ^= (v & 0xff) << 8;
    for (var b = 0; b < 8; b++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
    }
  }
  return crc;
}
