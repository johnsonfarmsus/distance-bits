// Bit-exact port of the TypeScript mulberry32 / chunkSeed. Both ends must derive
// the same chunk composition, so every step mirrors JS 32-bit semantics: values
// are kept as unsigned 32-bit ints, and Math.imul is (a*b) & 0xFFFFFFFF (Dart
// native ints wrap mod 2^64, so the low 32 bits of the product are exact).

const int _m32 = 0xFFFFFFFF;

int _imul(int a, int b) => (a * b) & _m32;

/// Deterministic 32-bit PRNG (mulberry32).
class Prng {
  int _s;
  Prng(int seed) : _s = seed & _m32;

  /// Uniform in [0, 1).
  double next() {
    _s = (_s + 0x6d2b79f5) & _m32;
    var t = _s;
    t = _imul(t ^ (t >> 15), t | 1);
    t = (t ^ ((t + _imul(t ^ (t >> 7), t | 61)) & _m32)) & _m32;
    return ((t ^ (t >> 14)) & _m32) / 4294967296.0;
  }

  /// Uniform integer in [0, n).
  int nextInt(int n) => (next() * n).floor();
}

/// Mix a message id and chunk index into a seed (splitmix-style finalizer).
int chunkSeed(int msgId, int chunkIndex) {
  var x = ((((msgId & 0xff) << 24) & _m32) ^ (chunkIndex & _m32) ^ 0x9e3779b9) & _m32;
  x = _imul(x ^ (x >> 16), 0x85ebca6b);
  x = _imul(x ^ (x >> 13), 0xc2b2ae35);
  return (x ^ (x >> 16)) & _m32;
}
