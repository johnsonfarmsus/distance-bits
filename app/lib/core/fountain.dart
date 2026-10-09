import 'dart:math' as math;
import 'dart:typed_data';

import 'prng.dart';

/// Systematic LT fountain code over bytes (port of fountain.ts).
///
/// Chunk c < L is source byte c; chunk c >= L is the XOR of a pseudo-random set of
/// source bytes chosen from (msgId, c) via a robust soliton degree distribution.

/// Cumulative robust soliton distribution for L blocks (index d-1 => P(degree <= d)).
Float64List robustSolitonCdf(int L, {double c = 0.05, double delta = 0.5}) {
  if (L <= 1) return Float64List.fromList([1]);
  final R = c * math.log(L / delta) * math.sqrt(L);
  final rho = Float64List(L);
  final tau = Float64List(L);
  rho[0] = 1 / L;
  for (var d = 2; d <= L; d++) {
    rho[d - 1] = 1 / (d * (d - 1));
  }
  final spike = math.max(1, math.min(L, _jsRound(L / R)));
  for (var d = 1; d < spike; d++) {
    tau[d - 1] = R / (d * L);
  }
  tau[spike - 1] = (R * math.log(R / delta)) / L;
  var z = 0.0;
  for (var i = 0; i < L; i++) {
    z += rho[i] + tau[i];
  }
  final cdf = Float64List(L);
  var acc = 0.0;
  for (var i = 0; i < L; i++) {
    acc += (rho[i] + tau[i]) / z;
    cdf[i] = acc;
  }
  cdf[L - 1] = 1;
  return cdf;
}

/// JS Math.round: halves round toward +infinity.
int _jsRound(double x) => (x + 0.5).floor();

class ChunkPlan {
  final int L;
  final int msgId;
  final Float64List _cdf;
  ChunkPlan(this.L, this.msgId) : _cdf = robustSolitonCdf(L);

  /// Sorted, distinct source indices XORed into chunk c.
  List<int> neighbors(int c) {
    if (c < L) return [c];
    final rng = Prng(chunkSeed(msgId, c));
    final u = rng.next();
    var d = 1;
    while (d < L && _cdf[d - 1] < u) {
      d++;
    }
    // Insertion-ordered set, like a JS Set: the draw sequence must match exactly.
    final set = <int>{};
    while (set.length < d) {
      set.add(rng.nextInt(L));
    }
    return set.toList()..sort();
  }
}

class LTEncoder {
  final Uint8List data;
  final ChunkPlan _plan;
  LTEncoder(this.data, int msgId) : _plan = ChunkPlan(data.length, msgId);

  int chunk(int c) {
    var v = 0;
    for (final i in _plan.neighbors(c)) {
      v ^= data[i];
    }
    return v;
  }
}

class _Eq {
  List<int> idx;
  int val;
  _Eq(this.idx, this.val);
}

class LTDecoder {
  final int L;
  final int msgId;
  final ChunkPlan _plan;
  final Int16List _solved;
  int _solvedCount = 0;
  final Map<int, _Eq> _eqs = {};
  final List<Set<int>> _byUnknown;
  final Set<int> _seen = {};
  int _nextEqId = 0;
  int _lastGaussianAt = 0;
  int received = 0;

  LTDecoder(this.L, this.msgId)
      : _plan = ChunkPlan(L, msgId),
        _solved = Int16List(L)..fillRange(0, L, -1),
        _byUnknown = List.generate(L, (_) => <int>{});

  int get progress => _solvedCount;
  bool get complete => _solvedCount == L;

  Uint8List? result() => complete ? Uint8List.fromList(_solved) : null;

  /// Feed chunk c with value v. Returns true if it was new information.
  bool add(int c, int v) {
    if (_seen.contains(c) || complete) return false;
    _seen.add(c);
    received++;
    final idx = <int>[];
    var val = v & 0xff;
    for (final i in _plan.neighbors(c)) {
      if (_solved[i] >= 0) {
        val ^= _solved[i];
      } else {
        idx.add(i);
      }
    }
    if (idx.isEmpty) return false;
    _insert(_Eq(idx, val));
    if (!complete && _eqs.length >= L - _solvedCount) _gaussian();
    return true;
  }

  void _insert(_Eq eq) {
    final queue = <_Eq>[eq];
    while (queue.isNotEmpty) {
      final e = queue.removeLast();
      if (e.idx.any((k) => _solved[k] >= 0)) {
        for (final k in e.idx) {
          if (_solved[k] >= 0) e.val ^= _solved[k];
        }
        e.idx = e.idx.where((k) => _solved[k] < 0).toList();
      }
      if (e.idx.isEmpty) continue;
      if (e.idx.length == 1) {
        final u = e.idx[0];
        if (_solved[u] >= 0) continue;
        _solved[u] = e.val;
        _solvedCount++;
        for (final id in _byUnknown[u].toList()) {
          final other = _eqs.remove(id)!;
          for (final k in other.idx) {
            _byUnknown[k].remove(id);
          }
          other.idx = other.idx.where((k) => k != u).toList();
          other.val ^= e.val;
          queue.add(other);
        }
        _byUnknown[u].clear();
      } else {
        final id = _nextEqId++;
        _eqs[id] = e;
        for (final k in e.idx) {
          _byUnknown[k].add(id);
        }
      }
    }
  }

  /// Fallback when peeling stalls: GF(2) elimination on the remaining unknowns.
  void _gaussian() {
    final unknowns = <int>[];
    for (var i = 0; i < L; i++) {
      if (_solved[i] < 0) unknowns.add(i);
    }
    final n = unknowns.length;
    if (n == 0 || n > 2048) return;
    if (_eqs.length < _lastGaussianAt + math.max(4, n >> 4)) return;
    _lastGaussianAt = _eqs.length;
    final col = <int, int>{};
    for (var i = 0; i < n; i++) {
      col[unknowns[i]] = i;
    }
    final words = (n + 31) >> 5;
    final rows = <_Row>[];
    for (final e in _eqs.values) {
      final bits = Uint32List(words);
      for (final k in e.idx) {
        final ci = col[k]!;
        bits[ci >> 5] |= 1 << (ci & 31);
      }
      rows.add(_Row(bits, e.val));
    }
    final pivotRow = List<_Row?>.filled(n, null);
    int bit(_Row r, int c) => (r.bits[c >> 5] >> (c & 31)) & 1;
    var rank = 0;
    for (final row in rows) {
      for (var ci = 0; ci < n; ci++) {
        final p = pivotRow[ci];
        if (p != null && bit(row, ci) == 1) {
          for (var w = 0; w < words; w++) {
            row.bits[w] ^= p.bits[w];
          }
          row.val ^= p.val;
        }
      }
      var lead = -1;
      for (var ci = 0; ci < n; ci++) {
        if (bit(row, ci) == 1) {
          lead = ci;
          break;
        }
      }
      if (lead < 0) continue;
      for (var cj = 0; cj < n; cj++) {
        final q = pivotRow[cj];
        if (q != null && bit(q, lead) == 1) {
          for (var w = 0; w < words; w++) {
            q.bits[w] ^= row.bits[w];
          }
          q.val ^= row.val;
        }
      }
      pivotRow[lead] = row;
      rank++;
    }
    if (rank < n) return;
    for (var i = 0; i < n; i++) {
      _solved[unknowns[i]] = pivotRow[i]!.val;
    }
    _solvedCount = L;
    _eqs.clear();
    for (final s in _byUnknown) {
      s.clear();
    }
  }
}

class _Row {
  final Uint32List bits;
  int val;
  _Row(this.bits, this.val);
}
