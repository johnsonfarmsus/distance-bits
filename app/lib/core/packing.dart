import 'dart:math' as math;

import 'config.dart';

/// A "group" is 7 payload symbols from a k-color palette, read as a base-k number
/// carrying floor(7·log2 k) bits: k=2 -> 7, k=3 -> 11, k=4 -> 14.
int bitsPerGroup(int k) => (groupSymbols * (math.log(k) / math.ln2) + 1e-9).floor();

int groupsFor(int nbits, int k) => (nbits / bitsPerGroup(k)).ceil();

List<int> encodeGroup(int value, int k) {
  final out = List<int>.filled(groupSymbols, 0);
  var v = value;
  for (var i = groupSymbols - 1; i >= 0; i--) {
    out[i] = v % k;
    v = v ~/ k;
  }
  return out;
}

int? decodeGroup(List<int?> digits, int k) {
  var v = 0;
  for (var i = 0; i < groupSymbols; i++) {
    final d = digits[i];
    if (d == null || d < 0 || d >= k) return null;
    v = v * k + d;
  }
  return v < (1 << bitsPerGroup(k)) ? v : null;
}

/// Pack bits into groups (zero-padded to a group boundary); returns symbols.
List<int> bitsToSymbols(List<int> bits, int k) {
  final b = bitsPerGroup(k);
  final groups = groupsFor(bits.length, k);
  final out = <int>[];
  for (var g = 0; g < groups; g++) {
    var v = 0;
    for (var i = 0; i < b; i++) {
      final idx = g * b + i;
      v = v * 2 + (idx < bits.length ? bits[idx] : 0);
    }
    out.addAll(encodeGroup(v, k));
  }
  return out;
}

/// Unpack symbols (grouped by 7) into bits. For k = 2 or 4 each digit maps to its
/// own bits, so an unknown symbol blanks only those; for k = 3 it blanks the group.
List<int?> symbolsToBits(List<int?> symbols, int k) {
  final b = bitsPerGroup(k);
  final out = <int?>[];
  final per = k == 2 ? 1 : (k == 4 ? 2 : 0);
  if (per > 0) {
    for (var g = 0; g + groupSymbols <= symbols.length; g += groupSymbols) {
      for (var i = 0; i < groupSymbols; i++) {
        final d = symbols[g + i];
        final ok = d != null && d >= 0 && d < k;
        for (var j = per - 1; j >= 0; j--) {
          out.add(ok ? (d >> j) & 1 : null);
        }
      }
    }
    return out;
  }
  for (var g = 0; g + groupSymbols <= symbols.length; g += groupSymbols) {
    final v = decodeGroup(symbols.sublist(g, g + groupSymbols), k);
    for (var i = b - 1; i >= 0; i--) {
      out.add(v == null ? null : (v >> i) & 1);
    }
  }
  return out;
}
