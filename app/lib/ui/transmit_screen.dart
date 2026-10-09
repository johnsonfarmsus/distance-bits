import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/core.dart';
import 'image_convert.dart';

/// Native brightness control (ios/Runner/AppDelegate.swift).
const _screen = MethodChannel('distance_bits/screen');

/// Native camera control (manual exposure), ios/Runner/AppDelegate.swift.
const _camera = MethodChannel('distance_bits/camera');

const _palette = [Color(0xFF000000), Color(0xFFFFFFFF), Color(0xFFFF0000), Color(0xFF00FF00), Color(0xFF0000FF)];

/// Full-screen transmitter: a short countdown to aim, then frames at the
/// configured rate until the screen is tapped or the receiver confirms delivery
/// (its flashlight blinks the ack rhythm, seen by this phone's front camera).
/// Pops with true when delivery was confirmed.
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

  // Delivery confirmation: front camera, very fast shutter, watching for the torch blink.
  CameraController? _front;
  final AckDetector _ack = AckDetector();
  final Stopwatch _clock = Stopwatch()..start();
  bool _busy = false, _delivered = false, _watching = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    _screen.invokeMethod('max').catchError((_) {});
    _ticker = createTicker(_onTick);
    _startWatching();
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

  Future<void> _startWatching() async {
    try {
      final front = (await availableCameras()).where((c) => c.lensDirection == CameraLensDirection.front).firstOrNull;
      if (front == null) return;
      final cam = CameraController(front, ResolutionPreset.low, enableAudio: false, fps: 30,
          imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420);
      await cam.initialize();
      if (!mounted) {
        await cam.dispose();
        return;
      }
      _front = cam;
      // Shortest shutter, lowest ISO: only a torch seen head-on saturates.
      try {
        final info = Map<String, dynamic>.from(await _camera.invokeMethod('info', {'id': front.name}) as Map);
        await _camera.invokeMethod('manual', {'id': front.name, 'dur': math.max(1 / 4000, (info['minDur'] as num).toDouble()), 'iso': (info['minISO'] as num).toDouble()});
      } catch (_) {
        await cam.setExposureOffset(-2).catchError((_) => 0.0);
      }
      await cam.startImageStream((img) {
        if (_busy || _delivered) return;
        _busy = true;
        try {
          final f = CamFrame(img, front.sensorOrientation);
          if (f.supported && _ack.add(f.coarse(96), _clock.elapsedMicroseconds / 1000)) _onDelivered();
        } finally {
          _busy = false;
        }
      });
      if (mounted) setState(() => _watching = true);
    } catch (_) {
      // No front camera access: sending still works, just without auto-stop.
    }
  }

  void _onDelivered() {
    if (_delivered) return;
    _delivered = true;
    _ticker.stop();
    HapticFeedback.heavyImpact();
    if (mounted) setState(() {});
    Future<void>.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) Navigator.of(context).pop(true);
    });
  }

  Future<void> _stopWatching() async {
    final cam = _front;
    _front = null;
    if (cam == null) return;
    try {
      if (cam.value.isStreamingImages) await cam.stopImageStream();
    } catch (_) {}
    await cam.dispose();
  }

  @override
  void dispose() {
    _stopWatching();
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
        onTap: () => Navigator.of(context).pop(_delivered),
        child: _delivered
            ? const Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.check_circle, color: Color(0xFF4ADE80), size: 120),
                  SizedBox(height: 12),
                  Text('Delivered', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, color: Colors.white)),
                ]),
              )
            : _countdown > 0
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('$_countdown', style: const TextStyle(fontSize: 96, fontWeight: FontWeight.w700, color: Colors.white)),
                  const SizedBox(height: 12),
                  const Text('Point this screen at the receiver', style: TextStyle(color: Colors.white70, fontSize: 18)),
                  const SizedBox(height: 6),
                  Text('$cfg · tap anytime to stop', style: const TextStyle(color: Colors.white38)),
                  const SizedBox(height: 4),
                  Text(_watching ? 'Stops by itself when the receiver confirms' : '', style: const TextStyle(color: Colors.white38)),
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
