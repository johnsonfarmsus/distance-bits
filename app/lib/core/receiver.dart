import 'dart:typed_data';

import 'colors.dart';
import 'config.dart';
import 'fountain.dart';
import 'framing.dart';
import 'packing.dart';
import 'payload.dart';

/// One accepted camera frame, reduced to per-cell colors (null = unclassifiable).
class Observation {
  final double t;
  final List<int?> cells;
  const Observation(this.t, this.cells);
}

enum ConfigSource { beacon, manual, auto }

class FrameLog {
  final double t;
  final int? seq, marker;
  final int lost;
  final String kind; // beacon-bit | separator | payload | unparsed
  final String symbols;
  final String state;
  const FrameLog(this.t, this.seq, this.marker, this.lost, this.kind, this.symbols, this.state);
}

class ReceiverEvents {
  final void Function(Config cfg, ConfigSource source)? onConfig;
  final void Function(Header h)? onHeader;
  final void Function(int solved, int total, int received)? onProgress;
  final void Function(Payload payload, Uint8List bytes, Header h)? onDone;

  /// Decode completed but the payload CRC failed; the receiver reset and keeps listening.
  final void Function(Uint8List bytes, Header h)? onCrcFail;

  /// An encrypted message decoded but couldn't be opened: no key, or a different code.
  final void Function(Uint8List bytes, Header h)? onLocked;
  final void Function(FrameLog entry)? onFrame;
  const ReceiverEvents({this.onConfig, this.onHeader, this.onProgress, this.onDone, this.onCrcFail, this.onLocked, this.onFrame});
}

class ReceiverStats {
  int observed = 0, parsed = 0, unparsed = 0, lostFrames = 0, headers = 0, epochs = 0;
  int chunksAdded = 0, chunksUnknown = 0, beacons = 0, blocksLost = 0, blocksBad = 0, crcFailures = 0;
}

const int _autoWindow = 12;
const int _autoMin = 6;
const int _colorWindow = 240;
const int _colorMin = 3;

/// The colour at least 3/4 of the cells agree on (null if none does).
int? majorityColor(List<int?> cells) {
  if (cells.isEmpty) return null;
  final counts = <int, int>{};
  for (final c in cells) {
    if (c != null) counts[c] = (counts[c] ?? 0) + 1;
  }
  for (final e in counts.entries) {
    if (e.value * 4 >= cells.length * 3) return e.key;
  }
  return null;
}

/// Returns the common color if every cell is the same non-null color, else null.
int? uniformColor(List<int?> cells) {
  if (cells.isEmpty || cells[0] == null) return null;
  final c = cells[0];
  for (var i = 1; i < cells.length; i++) {
    if (cells[i] != c) return null;
  }
  return c;
}

/// Frame kind judged purely by structure: far = one color; mid = halves uniform, one black;
/// near = exactly one black cell.
PresetName? detectStructure(List<int?> cells, int? uniform) {
  if (uniform != null) return PresetName.far;
  final n = cells.length;
  if (n % 2 == 0 && n >= 2) {
    final top = uniformColor(cells.sublist(0, n ~/ 2));
    final bottom = uniformColor(cells.sublist(n ~/ 2));
    if (top != null && bottom != null && ((top == Col.k) != (bottom == Col.k))) return PresetName.mid;
  }
  var k = 0;
  for (final c in cells) {
    if (c == null) return null;
    if (c == Col.k) k++;
  }
  return k == 1 ? PresetName.near : null;
}

class _Parsed {
  final int marker;
  final List<int?> symbols;
  _Parsed(this.marker, this.symbols);
}

/// Consumes accepted frames and drives the fountain decoder (port of receiver.ts).
class Receiver {
  Config? config;
  Header? header;
  LTDecoder? decoder;
  bool done = false;
  final ReceiverStats stats = ReceiverStats();
  ConfigSource? configSource;
  final ReceiverEvents events;

  /// Turns decoded wire bytes into a payload container: decrypts when the header
  /// says encrypted (null = can't). Without one, encrypted messages are reported
  /// through [ReceiverEvents.onLocked].
  Uint8List? Function(Uint8List wire, Header h)? unwrap;

  bool _searching = true;
  List<int?> _buf = [];
  int? _lastSeq;
  double _lastT = 0;
  List<int> _beaconBits = [];
  int _blocksTotal = 0, _blockChunks = 1, _blocksDone = 0, _groupsDone = 0;
  final List<int?> _epochBitBuf = [];
  List<int> _headerSyms = [];
  int _copiesLeft = 0;
  final List<(double, PresetName?)> _autoWin = [];

  /// A header decoded under the current config: preset and palette are proven,
  /// so auto-detection stops second-guessing them (it may still refine fps).
  bool _confirmed = false;
  final List<int> _colorHistory = [];

  Receiver({this.events = const ReceiverEvents(), Config? manualConfig, this.unwrap}) {
    if (manualConfig != null) setConfig(manualConfig, ConfigSource.manual);
  }

  /// Always sample the finest grid (2×4); the receiver reduces it itself.
  (int, int) get samplingGrid => (presets[PresetName.near]!.cols, presets[PresetName.near]!.rows);

  void setConfig(Config cfg, ConfigSource source) {
    config = cfg;
    configSource = source;
    _confirmed = false;
    _searching = true;
    _buf = [];
    _lastSeq = null;
    _blocksTotal = 0;
    events.onConfig?.call(cfg, source);
  }

  void observe(Observation obs0) {
    stats.observed++;
    // In Far, whole-screen frames count as uniform when 3/4 of the samples agree.
    // Elsewhere (and before the mode is known) stay strict: a Near frame can have
    // 6 of 8 cells the same colour by chance, and would be mistaken for Far.
    final uniform = config?.preset == PresetName.far ? majorityColor(obs0.cells) : uniformColor(obs0.cells);
    if (configSource != ConfigSource.manual && configSource != ConfigSource.beacon) _autoDetect(obs0, uniform);
    final obs = Observation(obs0.t, _reduceCells(obs0.cells));
    if (uniform != null) {
      _onUniform(uniform, obs);
      if (config?.preset != PresetName.far) return;
    }
    if (config == null) {
      _log(obs, null, null, 0, 'unparsed', '');
      return;
    }
    final parsed = _parse(obs.cells, uniform);
    if (parsed == null) {
      stats.unparsed++;
      _log(obs, null, null, 0, 'unparsed', '');
      return;
    }
    stats.parsed++;
    final (seq, lost) = _trackSeq(obs.t, parsed.marker);
    stats.lostFrames += lost;
    for (var s = seq - lost; s < seq; s++) {
      for (var i = 0; i < _symbolsAt(s); i++) {
        _push(null);
      }
    }
    for (final s in parsed.symbols) {
      _push(s);
    }
    _log(obs, seq, parsed.marker, lost, parsed.symbols.isNotEmpty ? 'payload' : 'separator', parsed.symbols.map((s) => s == null ? '?' : '$s').join());
  }

  List<int?> _reduceCells(List<int?> cells) {
    final cfg = config;
    if (cfg == null) return cells;
    final p = presets[cfg.preset]!;
    if (cells.length == p.cols * p.rows) return cells;
    // Whole-screen (Far) and half-screen (Mid) colours tolerate a stray sample,
    // e.g. a grid point that lands on the bezel: 3 of every 4 points must agree.
    if (cfg.preset == PresetName.far) return [majorityColor(cells)];
    if (cfg.preset == PresetName.mid && cells.length % 2 == 0) {
      final half = cells.length ~/ 2;
      return [majorityColor(cells.sublist(0, half)), majorityColor(cells.sublist(half))];
    }
    return cells;
  }

  // ---- structure-based auto configuration ----

  void _autoDetect(Observation obs, int? uniform) {
    final kind = detectStructure(obs.cells, uniform);
    var hasB = false, hasG = false;
    for (final c in obs.cells) {
      if (c == Col.b) hasB = true;
      if (c == Col.g) hasG = true;
    }
    _autoWin.add((obs.t, kind));
    if (_autoWin.length > _autoWindow) _autoWin.removeAt(0);
    _colorHistory.add((hasB ? 2 : 0) | (hasG ? 1 : 0));
    if (_colorHistory.length > _colorWindow) _colorHistory.removeAt(0);
    if (_autoWin.length < _autoMin) return;

    final votes = <PresetName, int>{};
    for (final e in _autoWin) {
      if (e.$2 != null) votes[e.$2!] = (votes[e.$2!] ?? 0) + 1;
    }
    if (votes.isEmpty) return;
    // Highest vote; ties keep first-inserted order like the TS stable sort.
    var preset = votes.keys.first;
    for (final k in votes.keys) {
      if (votes[k]! > votes[preset]!) preset = k;
    }
    final n = votes[preset]!;
    if (n < _autoMin) return;

    var blue = 0, green = 0;
    for (final h in _colorHistory) {
      if (h & 2 != 0) blue++;
      if (h & 1 != 0) green++;
    }
    final cur = config;
    var palette = cur?.palette ?? PaletteName.wr;
    if (blue >= _colorMin) {
      palette = PaletteName.rgbw;
    } else if (green >= _colorMin) {
      palette = palette == PaletteName.rgbw && _colorHistory.length < _colorWindow ? PaletteName.rgbw : PaletteName.rgw;
    } else if (_colorHistory.length >= _colorWindow) {
      palette = PaletteName.wr;
    }

    // Frame rate from accepted-frame spacing. Missed frames only ever make gaps
    // longer, so use the lower quartile, not the mode: one clean consecutive pair
    // in four is enough.
    final dts = <double>[
      for (var i = 1; i < _autoWin.length; i++)
        if (_autoWin[i].$1 - _autoWin[i - 1].$1 > 0) _autoWin[i].$1 - _autoWin[i - 1].$1,
    ]..sort();
    var fps = cur?.fps ?? fpsValues[0];
    if (dts.length >= 4) {
      final dt = dts[dts.length ~/ 4];
      fps = fpsValues[0];
      for (final c in fpsValues) {
        if ((1000 / c - dt).abs() < (1000 / fps - dt).abs()) fps = c;
      }
    }

    final cfg = Config(preset, palette, fps);
    if (cur == cfg) return;
    // An fps-only change re-times frame counting; it doesn't invalidate symbols already read.
    if (cur != null && (_confirmed || (cur.preset == cfg.preset && cur.palette == cfg.palette))) {
      if (cur.fps != fps) config = cur.copyWith(fps: fps);
      return;
    }
    if (cur != null && cur.preset != cfg.preset && n < _autoWindow - 2) return;
    setConfig(cfg, ConfigSource.auto);
  }

  // ---- beacon ----

  void _onUniform(int c, Observation obs) {
    if (c == Col.k) return;
    if (c != Col.w && c != Col.r) {
      _beaconBits = [];
      return;
    }
    _beaconBits.add(c == Col.r ? 1 : 0);
    if (_beaconBits.length > beaconBits) _beaconBits.removeAt(0);
    if (_beaconBits.length == beaconBits) {
      final cfg = decodeBeacon(_beaconBits);
      if (cfg != null) {
        stats.beacons++;
        _beaconBits = [];
        setConfig(cfg, ConfigSource.beacon);
        _log(obs, null, null, 0, 'beacon-bit', 'BEACON');
        return;
      }
    }
    if (config?.preset != PresetName.far) _log(obs, null, null, 0, 'beacon-bit', c == Col.r ? '1' : '0');
  }

  // ---- frame parsing ----

  _Parsed? _parse(List<int?> cells, int? uniform) {
    final cfg = config!;
    if (cfg.preset == PresetName.far) {
      if (uniform == null) return null;
      if (uniform == Col.k) return _Parsed(1, []);
      final s = symbolOf(cfg.palette, uniform);
      return _Parsed(0, [s < 0 ? null : s]);
    }
    final p = presets[cfg.preset]!;
    if (cells.length != p.cols * p.rows) return null;
    var marker = -1;
    for (var i = 0; i < cells.length; i++) {
      if (cells[i] == Col.k) {
        if (marker >= 0) return null;
        marker = i;
      }
    }
    if (marker < 0) return null;
    final symbols = <int?>[];
    for (var i = 0; i < cells.length; i++) {
      if (i == marker) continue;
      final c = cells[i];
      final s = c == null ? -1 : symbolOf(cfg.palette, c);
      symbols.add(s < 0 ? null : s);
    }
    return _Parsed(marker, symbols);
  }

  // ---- sequence tracking ----

  (int, int) _trackSeq(double t, int marker) {
    final cfg = config!;
    final m = presets[cfg.preset]!.markerPeriod;
    final last = _lastSeq;
    if (last == null) {
      _lastSeq = marker;
      _lastT = t;
      return (marker, 0);
    }
    final period = framePeriodMs(cfg.fps);
    var dt = ((t - _lastT) / period).round();
    if (dt < 1) dt = 1;
    final cand = last + dt;
    final r = (((marker - cand) % m) + m) % m;
    final up = cand + r;
    final down = up - m;
    var seq = down > last && cand - down <= up - cand ? down : up;
    while (seq <= last) {
      seq += m;
    }
    final lost = seq - last - 1;
    _lastSeq = seq;
    _lastT = t;
    return (seq, lost);
  }

  int _symbolsAt(int seq) {
    switch (config!.preset) {
      case PresetName.near:
        return groupSymbols;
      case PresetName.mid:
        return 1;
      case PresetName.far:
        return seq % 2 == 0 ? 1 : 0;
    }
  }

  // ---- symbol stream ----

  void _push(int? sym) {
    _buf.add(sym);
    final cfg = config!;
    final k = palettes[cfg.palette]!.length;
    if (_searching) {
      final one = groupsFor(headerBits, k) * groupSymbols;
      final rep = presets[cfg.preset]!.headerRepeat;
      final need = one * rep;
      if (_buf.length > need * 3) _buf.removeRange(0, _buf.length - need * 2);
      if (_buf.length < one) return;
      final merged = _buf.sublist(_buf.length - one);
      for (var r = 1; r < rep && merged.contains(null); r++) {
        final off = _buf.length - one * (r + 1);
        if (off < 0) break;
        for (var i = 0; i < one; i++) {
          merged[i] ??= _buf[off + i];
        }
      }
      if (merged.contains(null)) return;
      final h = decodeHeader(symbolsToBits(merged, k));
      if (h == null) return;
      _onHeader(h);
      _buf = [];
      _searching = false;
      _blockChunks = presets[cfg.preset]!.blockChunks;
      _blocksTotal = h.epochChunks ~/ _blockChunks;
      _blocksDone = 0;
      _groupsDone = 0;
      _epochBitBuf.clear();
      _headerSyms = bitsToSymbols(encodeHeader(h), k);
      _copiesLeft = rep - 1;
    } else {
      if (_copiesLeft > 0) {
        final n = _headerSyms.length;
        if (_buf.length < n) return;
        var consistent = true;
        for (var i = 0; i < n && consistent; i++) {
          if (_buf[i] != null && _buf[i] != _headerSyms[i]) consistent = false;
        }
        if (consistent) {
          _buf.removeRange(0, n);
          _copiesLeft--;
          if (_copiesLeft > 0) return;
        } else {
          _copiesLeft = 0;
        }
      }
      _drainEpoch(k);
    }
  }

  void _drainEpoch(int k) {
    final bb = blockBits(_blockChunks);
    while (_blocksDone < _blocksTotal && _buf.length >= (_groupsDone + 1) * groupSymbols) {
      final g = _buf.sublist(_groupsDone * groupSymbols, (_groupsDone + 1) * groupSymbols);
      _groupsDone++;
      _epochBitBuf.addAll(symbolsToBits(g, k));
      while (_blocksDone < _blocksTotal && _epochBitBuf.length >= (_blocksDone + 1) * bb) {
        _finishBlock(_epochBitBuf.sublist(_blocksDone * bb, (_blocksDone + 1) * bb), _blocksDone);
        _blocksDone++;
      }
    }
    if (_blocksDone >= _blocksTotal) {
      stats.epochs++;
      _buf = [];
      _searching = true;
    }
  }

  void _finishBlock(List<int?> bits, int block) {
    final h = header!;
    final n = _blockChunks;
    final bytes = decodeBlock(bits, n, h.msgId, h.epoch, block);
    if (bytes == null) {
      if (bits.contains(null)) {
        stats.blocksLost++;
      } else {
        stats.blocksBad++;
      }
      stats.chunksUnknown += n;
      return;
    }
    if (done) return;
    final dec = decoder!;
    final base = h.epoch * h.epochChunks + block * n;
    for (var i = 0; i < n; i++) {
      stats.chunksAdded++;
      dec.add(base + i, bytes[i]);
    }
    events.onProgress?.call(dec.progress, dec.L, dec.received);
    if (dec.complete) {
      final out = dec.result()!;
      final encrypted = h.flags & flagEncrypted != 0;
      final container = encrypted ? unwrap?.call(out, h) : out;
      final payload = container == null ? null : decodePayload(container);
      if (payload != null) {
        done = true;
        events.onDone?.call(payload, out, h);
      } else if (encrypted) {
        // Most likely a message under a different code (block CRCs make a corrupt
        // decode rare). Report it once and ignore the rest of this message.
        done = true;
        events.onLocked?.call(out, h);
      } else {
        stats.crcFailures++;
        decoder = LTDecoder(h.length, h.msgId);
        events.onCrcFail?.call(out, h);
      }
    }
  }

  void _onHeader(Header h) {
    stats.headers++;
    _confirmed = true;
    final cur = header;
    if (decoder == null || cur == null || cur.msgId != h.msgId || cur.length != h.length) {
      decoder = LTDecoder(h.length, h.msgId);
      done = false;
    }
    header = h;
    events.onHeader?.call(h);
  }

  void _log(Observation obs, int? seq, int? marker, int lost, String kind, String symbols) {
    events.onFrame?.call(FrameLog(obs.t, seq, marker, lost, kind, symbols, _searching ? 'search' : 'epoch'));
  }
}

/// Accept a frame when `agree` consecutive captures classify identically and differ
/// from the last accepted frame (the marker moves every frame).
class FrameAcceptor {
  List<int?>? _prev;
  int _run = 0;
  List<int?>? _lastAccepted;
  int agree;
  FrameAcceptor([this.agree = 2]);

  Observation? offer(List<int?> cells, double t) {
    final prev = _prev;
    if (prev != null && sameCells(prev, cells)) {
      _run++;
    } else {
      _run = 1;
    }
    _prev = cells;
    if (_run < agree) return null;
    final last = _lastAccepted;
    if (last != null && sameCells(last, cells)) return null;
    _lastAccepted = cells;
    return Observation(t, cells);
  }

  void reset() {
    _prev = null;
    _run = 0;
    _lastAccepted = null;
  }
}

bool sameCells(List<int?> a, List<int?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
