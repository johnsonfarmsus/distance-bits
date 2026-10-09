/// MSB-first bit writer.
class BitWriter {
  final List<int> _bits = [];
  void write(int value, int nbits) {
    for (var i = nbits - 1; i >= 0; i--) {
      _bits.add((value >> i) & 1);
    }
  }

  void writeBytes(List<int> bytes) {
    for (final b in bytes) {
      write(b, 8);
    }
  }

  int get length => _bits.length;
  List<int> toBits() => List.of(_bits);
  List<int> toBytes() {
    final out = List<int>.filled((_bits.length + 7) ~/ 8, 0);
    for (var i = 0; i < _bits.length; i++) {
      if (_bits[i] != 0) out[i >> 3] |= 0x80 >> (i & 7);
    }
    return out;
  }
}

/// MSB-first bit reader over bits (0/1; null = unknown).
class BitReader {
  int _pos = 0;
  final List<int?> _bits;
  BitReader(this._bits);

  /// Returns null if any bit in the field is unknown or past the end.
  int? read(int nbits) {
    var v = 0;
    var unknown = false;
    for (var i = 0; i < nbits; i++) {
      final b = _pos < _bits.length ? _bits[_pos] : null;
      _pos++;
      if (b == null) {
        unknown = true;
      } else {
        v = (v << 1) | b;
      }
    }
    return unknown ? null : v;
  }
}

List<int> bytesToBits(List<int> bytes) => (BitWriter()..writeBytes(bytes)).toBits();
