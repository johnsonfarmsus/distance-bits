import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/core.dart';

/// Native brightness control (ios/Runner/AppDelegate.swift).
const _screen = MethodChannel('distance_bits/screen');

const _palette = [Color(0xFF000000), Color(0xFFFFFFFF), Color(0xFFFF0000), Color(0xFF00FF00), Color(0xFF0000FF)];

/// Full-screen transmitter: a short countdown to aim, then frames at the
/// configured rate until the screen is tapped.
class TransmitScreen extends StatefulWidget {
  final Transmitter transmitter;
  const TransmitScreen({super.key, required this.transmitter});
  @override
  State<TransmitScreen> createState() => _TransmitScreenState();
}

class _TransmitScreenState extends State<TransmitScreen> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<Frame?> _frame = ValueNotifier(null);
  int _countdown = 3;
  Timer? _countdownTimer;
  Duration _start = Duration.zero;
  bool _started = false;
  int _shown = 0;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    _screen.invokeMethod('max').catchError((_) {});
    _ticker = createTicker(_onTick);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      setState(() => _countdown--);
      if (_countdown <= 0) {
        t.cancel();
        _ticker.start();
      }
    });
  }

  void _onTick(Duration elapsed) {
    if (!_started) {
      _started = true;
      _start = elapsed;
    }
    final period = 1000 / widget.transmitter.cfg.fps;
    final due = ((elapsed - _start).inMicroseconds / 1000 / period).floor() + 1;
    if (due - _shown > 30) _shown = due - 1; // app was paused; don't replay a backlog
    Frame? f;
    while (_shown < due) {
      // Frames we couldn't show in time are skipped; the receiver counts them as lost.
      f = widget.transmitter.next();
      _shown++;
    }
    if (f != null) _frame.value = f;
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _ticker.dispose();
    WakelockPlus.disable();
    _screen.invokeMethod('restore').catchError((_) {});
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cfg = widget.transmitter.cfg;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: _countdown > 0
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('$_countdown', style: const TextStyle(fontSize: 96, fontWeight: FontWeight.w700, color: Colors.white)),
                  const SizedBox(height: 12),
                  const Text('Point this screen at the receiver', style: TextStyle(color: Colors.white70, fontSize: 18)),
                  const SizedBox(height: 6),
                  Text('$cfg · tap anytime to stop', style: const TextStyle(color: Colors.white38)),
                ]),
              )
            : SizedBox.expand(child: CustomPaint(painter: _FramePainter(_frame, cfg))),
      ),
    );
  }
}

class _FramePainter extends CustomPainter {
  final ValueNotifier<Frame?> frame;
  final Config cfg;
  _FramePainter(this.frame, this.cfg) : super(repaint: frame);

  @override
  void paint(Canvas canvas, Size size) {
    final f = frame.value;
    if (f == null) return;
    final paint = Paint()..isAntiAlias = false;
    if (f.layout == Layout.blob) {
      paint.color = _palette[f.cells[0]];
      canvas.drawRect(Offset.zero & size, paint);
      return;
    }
    final p = presets[cfg.preset]!;
    final cw = size.width / p.cols, ch = size.height / p.rows;
    for (var r = 0; r < p.rows; r++) {
      for (var c = 0; c < p.cols; c++) {
        paint.color = _palette[f.cells[r * p.cols + c]];
        canvas.drawRect(Rect.fromLTWH(c * cw, r * ch, cw + 0.5, ch + 0.5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_FramePainter old) => false;
}
