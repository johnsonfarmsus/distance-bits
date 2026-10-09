import 'bits.dart';
import 'config.dart';
import 'crc.dart';

// Beacon (32 bits, always 1x1 W/R symbol+separator pairs):
//   sync16 = 0xB5C2 | preset(2) palette(2) fps(2) reserved(2) | crc8 over 3 bytes
// Header (56 bits, session grid + palette, once per epoch):
//   sync8 = 0xD5 | msgId(8) | length(16) | epoch(8) | flags(8) | crc8 over 6 bytes
//   flags: bits 0-1 = epoch size code (8/16/32/64), bits 2-7 reserved
// Block: n chunk bytes | crc8(msgId, epoch, blockIndex, the n bytes)

const int beaconSync = 0xb5c2;
const int beaconBits = 32;
const int headerSync = 0xd5;
const int headerBits = 56;

List<int> encodeBeacon(Config cfg) {
  final w = BitWriter();
  w.write(beaconSync, 16);
  final preset = cfg.preset.index;
  final palette = cfg.palette.index;
  final fps = fpsValues.indexOf(cfg.fps);
  w.write((preset << 6) | (palette << 4) | (fps << 2), 8);
  w.write(crc8(w.toBytes(), 0, 3), 8);
  return w.toBits();
}

Config? decodeBeacon(List<int?> bits) {
  if (bits.length < beaconBits) return null;
  final r = BitReader(bits);
  if (r.read(16) != beaconSync) return null;
  final b2 = r.read(8);
  final crc = r.read(8);
  if (b2 == null || crc == null) return null;
  if (crc8([beaconSync >> 8, beaconSync & 0xff, b2]) != crc) return null;
  final pi = (b2 >> 6) & 3, li = (b2 >> 4) & 3, fi = (b2 >> 2) & 3;
  if (pi >= PresetName.values.length || li >= PaletteName.values.length || fi >= fpsValues.length) return null;
  return Config(PresetName.values[pi], PaletteName.values[li], fpsValues[fi]);
}

class Header {
  final int msgId;
  final int length;
  final int epoch;
  final int epochChunks;

  /// Flag bits other than the epoch size code.
  final int flags;
  const Header({required this.msgId, required this.length, required this.epoch, required this.epochChunks, this.flags = 0});

  @override
  bool operator ==(Object o) =>
      o is Header && o.msgId == msgId && o.length == length && o.epoch == epoch && o.epochChunks == epochChunks && o.flags == flags;
  @override
  int get hashCode => Object.hash(msgId, length, epoch, epochChunks, flags);
}

const int _sizeMask = 0x03;

List<int> encodeHeader(Header h) {
  final code = epochSizes.indexOf(h.epochChunks);
  if (code < 0) throw ArgumentError('bad epoch size ${h.epochChunks}');
  final w = BitWriter();
  w.write(headerSync, 8);
  w.write(h.msgId & 0xff, 8);
  w.write(h.length & 0xffff, 16);
  w.write(h.epoch & 0xff, 8);
  w.write((h.flags & ~_sizeMask & 0xff) | code, 8);
  w.write(crc8(w.toBytes(), 0, 6), 8);
  return w.toBits();
}

Header? decodeHeader(List<int?> bits) {
  if (bits.length < headerBits) return null;
  final r = BitReader(bits);
  if (r.read(8) != headerSync) return null;
  final msgId = r.read(8), length = r.read(16), epoch = r.read(8), flags = r.read(8), crc = r.read(8);
  if (msgId == null || length == null || epoch == null || flags == null || crc == null) return null;
  if (crc8([headerSync, msgId, length >> 8, length & 0xff, epoch, flags]) != crc) return null;
  if (length == 0) return null;
  return Header(msgId: msgId, length: length, epoch: epoch, epochChunks: epochSizes[flags & _sizeMask], flags: flags & ~_sizeMask);
}

int _blockCrc(int msgId, int epoch, int block, List<int> bytes) => crc8([msgId & 0xff, epoch & 0xff, block & 0xff, ...bytes]);

List<int> encodeBlock(int msgId, int epoch, int block, List<int> bytes) {
  final w = BitWriter();
  w.writeBytes(bytes);
  w.write(_blockCrc(msgId, epoch, block, bytes), 8);
  return w.toBits();
}

/// The block's chunk bytes, or null if any bit is unknown or the CRC fails.
List<int>? decodeBlock(List<int?> bits, int nChunks, int msgId, int epoch, int block) {
  if (bits.length < nChunks * 8 + 8) return null;
  final r = BitReader(bits);
  final bytes = <int>[];
  for (var i = 0; i < nChunks; i++) {
    final v = r.read(8);
    if (v == null) return null;
    bytes.add(v);
  }
  final crc = r.read(8);
  if (crc == null || crc != _blockCrc(msgId, epoch, block, bytes)) return null;
  return bytes;
}
