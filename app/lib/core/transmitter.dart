import 'dart:typed_data';

import 'colors.dart';
import 'config.dart';
import 'fountain.dart';
import 'framing.dart';
import 'packing.dart';

enum Layout { grid, blob }

enum Segment { beacon, header, payload }

/// One screen refresh worth of content.
class Frame {
  /// Monotonic frame counter; the marker position derives from it.
  final int seq;
  final Layout layout;

  /// Physical colors, row-major for grid; a single entry for blob.
  final List<int> cells;
  final Segment segment;
  final int epoch;
  const Frame(this.seq, this.layout, this.cells, this.segment, this.epoch);
}

/// Turns a payload into an endless frame sequence (port of transmitter.ts):
///   [beacon] header×r blocks | header×r blocks | ... (beacon every Nth epoch)
class Transmitter {
  final Config cfg;
  final Uint8List payload;
  final int msgId;
  final int beaconEvery;

  /// Header flag bits other than the epoch size (e.g. [flagEncrypted]).
  final int flags;
  late final int epochChunks;
  late final LTEncoder _encoder;
  late final int _k;
  late final Iterator<Frame> _it;
  int _seq = 0;

  Transmitter(this.cfg, this.payload, {required this.msgId, this.beaconEvery = defaultBeaconEvery, this.flags = 0}) {
    if (payload.isEmpty || payload.length > 0xffff) throw ArgumentError('payload must be 1..65535 bytes');
    _k = palettes[cfg.palette]!.length;
    _encoder = LTEncoder(payload, msgId);
    epochChunks = epochChunksFor(payload.length);
    _it = _run().iterator;
  }

  Frame next() {
    _it.moveNext();
    return _it.current;
  }

  /// Frames per epoch (header copies + blocks), for time estimates.
  double framesPerEpoch() {
    final p = presets[cfg.preset]!;
    final headerSyms = bitsToSymbols(encodeHeader(Header(msgId: 0, length: 1, epoch: 0, epochChunks: epochChunks)), _k).length * p.headerRepeat;
    final epochSyms = bitsToSymbols(List.filled(epochBits(epochChunks, p.blockChunks), 0), _k).length;
    return (headerSyms + epochSyms) / p.symbolsPerFrame;
  }

  /// Rough seconds for one pass with no losses.
  double estimateSeconds() {
    final epochs = (payload.length / epochChunks).ceil();
    final frames = epochs * framesPerEpoch() + (epochs / beaconEvery).ceil() * beaconBits * 2;
    return frames / cfg.fps;
  }

  Iterable<Frame> _run() sync* {
    final e = epochChunks;
    final p = presets[cfg.preset]!;
    final n = p.blockChunks;
    for (var epoch = 0;; epoch++) {
      if (epoch % beaconEvery == 0) yield* _blobBits(encodeBeacon(cfg), Segment.beacon, epoch);
      final e8 = epoch & 0xff;
      final header = encodeHeader(Header(msgId: msgId, length: payload.length, epoch: e8, epochChunks: e, flags: flags));
      final headerSyms = bitsToSymbols(header, _k);
      for (var r = 0; r < p.headerRepeat; r++) {
        yield* _symbols(headerSyms, Segment.header, epoch);
      }
      final bits = <int>[];
      for (var b = 0; b < e ~/ n; b++) {
        final bytes = List<int>.generate(n, (i) => _encoder.chunk(e8 * e + b * n + i));
        bits.addAll(encodeBlock(msgId, e8, b, bytes));
      }
      yield* _symbols(bitsToSymbols(bits, _k), Segment.payload, epoch);
    }
  }

  Iterable<Frame> _blobBits(List<int> bits, Segment segment, int epoch) sync* {
    for (final b in bits) {
      yield _frame(Layout.blob, [b == 1 ? Col.r : Col.w], segment, epoch);
      yield _frame(Layout.blob, [Col.k], segment, epoch);
    }
  }

  Iterable<Frame> _symbols(List<int> syms, Segment segment, int epoch) sync* {
    final pal = palettes[cfg.palette]!;
    final p = presets[cfg.preset]!;
    switch (cfg.preset) {
      case PresetName.near:
        for (var g = 0; g < syms.length; g += groupSymbols) {
          final cells = List<int>.filled(p.cols * p.rows, 0);
          final marker = _seq % p.markerPeriod;
          var s = g;
          for (var i = 0; i < cells.length; i++) {
            cells[i] = i == marker ? Col.k : pal[syms[s++]];
          }
          yield _frame(Layout.grid, cells, segment, epoch);
        }
      case PresetName.mid:
        for (final sym in syms) {
          final marker = _seq % 2;
          yield _frame(Layout.grid, marker == 0 ? [Col.k, pal[sym]] : [pal[sym], Col.k], segment, epoch);
        }
      case PresetName.far:
        for (final sym in syms) {
          yield _frame(Layout.blob, [pal[sym]], segment, epoch);
          yield _frame(Layout.blob, [Col.k], segment, epoch);
        }
    }
  }

  Frame _frame(Layout layout, List<int> cells, Segment segment, int epoch) => Frame(_seq++, layout, cells, segment, epoch);
}
