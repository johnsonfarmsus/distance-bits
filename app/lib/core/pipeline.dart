import 'dart:typed_data';

import 'colors.dart';
import 'config.dart';
import 'framing.dart';
import 'payload.dart';
import 'receiver.dart';
import 'vision.dart';

class CaptureRecord {
  final double t;
  final ScreenRect? rect;
  List<int?>? cells;
  String? rgb;
  bool accepted = false;
  FrameLog? frame;
  CaptureRecord(this.t, this.rect);
}

/// Pixels -> decoded message (port of the web app's pipeline.ts).
class RxPipeline {
  late final Receiver receiver;
  final RectTracker tracker = RectTracker();
  final Calibrator calibrator = Calibrator();
  final FrameAcceptor acceptor;
  ScreenRect? lastRect;
  List<Rgb> lastSamples = const [];
  List<int?> lastCells = const [];
  int captures = 0, accepted = 0;
  final List<CaptureRecord> log = [];
  bool keepLog = true;
  FrameLog? _pending;

  RxPipeline({
    int agree = 2,
    Config? manualConfig,
    void Function(Config, ConfigSource)? onConfig,
    void Function(Header)? onHeader,
    void Function(int, int, int)? onProgress,
    void Function(Payload, Uint8List, Header)? onDone,
    void Function(Uint8List, Header)? onCrcFail,
    void Function(Uint8List, Header)? onLocked,
    Uint8List? Function(Uint8List, Header)? unwrap,
  }) : acceptor = FrameAcceptor(agree) {
    receiver = Receiver(
      manualConfig: manualConfig,
      unwrap: unwrap,
      events: ReceiverEvents(
        onConfig: (c, s) {
          acceptor.reset();
          onConfig?.call(c, s);
        },
        onHeader: onHeader,
        onProgress: onProgress,
        onDone: onDone,
        onCrcFail: onCrcFail,
        onLocked: onLocked,
        onFrame: (f) => _pending = f,
      ),
    );
  }

  /// Feed one small captured image (≈160–320 px wide). If [sampler] is given, cell
  /// colours are read through it (e.g. from a full-resolution buffer) using the
  /// screen rect found in [img]; otherwise they are read from [img] itself.
  CaptureRecord process(RgbaImage img, double t, {List<Rgb> Function(ScreenRect rect, int cols, int rows)? sampler}) {
    captures++;
    final rect = tracker.update(findScreen(img), t);
    lastRect = rect;
    final rec = CaptureRecord(t, rect);
    final (cols, rows) = receiver.samplingGrid;
    List<int?> cells;
    if (rect != null) {
      final samples = sampler != null ? sampler(rect, cols, rows) : sampleCells(img, rect, cols, rows);
      calibrator.update(samples);
      cells = classifyCells(samples, calibrator.calib);
      lastSamples = samples;
      rec.rgb = samples.map((s) => [s.$1, s.$2, s.$3].map((c) => c.round().toRadixString(16).padLeft(2, '0')).join()).join('|');
    } else {
      // No screen visible: a black separator or nothing in view.
      cells = List<int?>.filled(cols * rows, Col.k);
    }
    lastCells = cells;
    rec.cells = cells;
    final obs = acceptor.offer(cells, t);
    if (obs != null) {
      accepted++;
      rec.accepted = true;
      _pending = null;
      receiver.observe(obs);
      rec.frame = _pending;
    }
    if (keepLog) {
      log.add(rec);
      if (log.length > 20000) log.removeRange(0, 5000);
    }
    return rec;
  }

  String csv() {
    final b = StringBuffer('t_ms,rect,cells,accepted,seq,marker,lost,kind,symbols,state,rgb\n');
    for (final r in log) {
      final f = r.frame;
      final cells = r.cells?.map((c) => c == null ? '?' : 'KWRGB'[c]).join() ?? '';
      b.writeln([
        r.t.toStringAsFixed(1), r.rect?.toString() ?? '', cells, r.accepted ? 1 : 0,
        f?.seq ?? '', f?.marker ?? '', f?.lost ?? '', f?.kind ?? '', f?.symbols ?? '', f?.state ?? '', r.rgb ?? '',
      ].join(','));
    }
    return b.toString();
  }
}
