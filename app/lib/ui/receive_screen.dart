import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/core.dart';
import 'image_convert.dart';
import 'theme.dart';

const _cellColors = [Color(0xFF000000), Color(0xFFFFFFFF), Color(0xFFFF3333), Color(0xFF33FF33), Color(0xFF3355FF)];

class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key});
  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> with WidgetsBindingObserver {
  CameraController? _cam;
  List<CameraDescription> _backs = [];
  int _lens = 0;
  String? _error;

  late RxPipeline _pipe;
  final Stopwatch _clock = Stopwatch()..start();
  bool _busy = false;
  int _lastUi = 0;

  String _status = 'Looking for a sender…';
  int _solved = 0, _total = 0;
  Payload? _result;
  String? _logPath;

  // Overlay
  ScreenRect? _rect;
  int _imgW = 1, _imgH = 1;
  List<int?> _cells = const [];

  // Diagnostics: capture rate, raw buffer shape, periodic log + snapshot saves.
  double _capFps = 0, _procMs = 0;
  double _lastCapT = -1;
  String _bufInfo = '';
  RgbaImage? _lastImg;
  Timer? _diagTimer;
  int _snapN = 0;
  String? _sessionStamp;

  // Exposure: meter on the sender's screen, then lock so the camera stops chasing the flashes.
  int _seenFrames = 0;
  bool _locked = false, _locking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _newPipeline();
    _startCamera();
    _diagTimer = Timer.periodic(const Duration(seconds: 3), (_) => _saveDiagnostics());
  }

  void _newPipeline() {
    _pipe = RxPipeline(
      onConfig: (c, s) => _status = 'Found a sender: ${_describe(c)}',
      onHeader: (h) {
        if (_result == null) _status = 'Receiving message (${h.length} bytes)…';
      },
      onProgress: (a, b, _) {
        _solved = a;
        _total = b;
      },
      onCrcFail: (_, __) => _status = 'A bad read slipped through; starting that message over…',
      onDone: (p, bytes, h) {
        _result = p;
        _status = 'Message received ✓';
        HapticFeedback.heavyImpact();
        _saveLog();
      },
    );
    _result = null;
    _solved = _total = 0;
  }

  String _describe(Config c) {
    const names = {PresetName.near: 'Near', PresetName.mid: 'Mid', PresetName.far: 'Far'};
    const cols = {PaletteName.rgbw: '4 colours', PaletteName.rgw: '3 colours', PaletteName.wr: '2 colours'};
    return '${names[c.preset]} · ${cols[c.palette]} · ${c.fps} fps';
  }

  Future<void> _startCamera() async {
    try {
      final all = await availableCameras();
      _backs = all.where((c) => c.lensDirection == CameraLensDirection.back).toList();
      if (_backs.isEmpty) throw 'No rear camera found';
      if (_lens >= _backs.length) _lens = 0;
      final cam = CameraController(
        _backs[_lens],
        ResolutionPreset.medium,
        enableAudio: false,
        fps: 60,
        imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420,
      );
      await cam.initialize();
      await cam.lockCaptureOrientation(DeviceOrientation.portraitUp).catchError((_) {});
      _cam = cam;
      _locked = false;
      _seenFrames = 0;
      await cam.startImageStream(_onImage);
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = 'Camera unavailable: $e\nAllow camera access in Settings → Distance Bits.');
    }
  }

  Future<void> _stopCamera() async {
    final cam = _cam;
    _cam = null;
    if (cam == null) return;
    try {
      if (cam.value.isStreamingImages) await cam.stopImageStream();
    } catch (_) {}
    await cam.dispose();
  }

  void _onImage(CameraImage img) {
    if (_busy) return; // drop a capture rather than queue them up
    _busy = true;
    try {
      final t = _clock.elapsedMicroseconds / 1000.0;
      if (_lastCapT >= 0) {
        final dt = t - _lastCapT;
        if (dt > 0) _capFps = _capFps == 0 ? 1000 / dt : _capFps * 0.95 + (1000 / dt) * 0.05;
      }
      _lastCapT = t;
      final rgba = toPortraitRgba(img, _backs[_lens].sensorOrientation);
      if (rgba == null) return;
      _bufInfo = '${img.width}×${img.height} rot ${_backs[_lens].sensorOrientation}';
      _lastImg = rgba;
      // Two agreeing captures per frame needs the camera at ~2× the sender's rate;
      // when it can't keep up, accept on a single capture instead.
      final txFps = _pipe.receiver.config?.fps ?? 30;
      _pipe.acceptor.agree = _capFps >= txFps * 1.7 ? 2 : 1;
      _pipe.process(rgba, t);
      _procMs = _procMs * 0.9 + ((_clock.elapsedMicroseconds / 1000.0) - t) * 0.1;
      _rect = _pipe.lastRect;
      _imgW = rgba.width;
      _imgH = rgba.height;
      _cells = _pipe.lastCells;
      if (_rect != null && !_locked && !_locking) {
        if (++_seenFrames > 30) _lockExposure();
      }
      final now = _clock.elapsedMilliseconds;
      if (now - _lastUi > 100 && mounted) {
        _lastUi = now;
        setState(() {});
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _lockExposure() async {
    final cam = _cam, r = _rect;
    if (cam == null || r == null) return;
    _locking = true;
    try {
      final pt = Offset((r.x + r.w / 2) / _imgW, (r.y + r.h / 2) / _imgH);
      await cam.setExposurePoint(pt).catchError((_) {});
      await cam.setFocusPoint(pt).catchError((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await cam.setExposureMode(ExposureMode.locked).catchError((_) {});
      await cam.setFocusMode(FocusMode.locked).catchError((_) {});
      _locked = true;
    } finally {
      _locking = false;
    }
  }

  Future<void> _unlockExposure() async {
    final cam = _cam;
    if (cam == null) return;
    await cam.setExposureMode(ExposureMode.auto).catchError((_) {});
    await cam.setFocusMode(FocusMode.auto).catchError((_) {});
    await cam.setExposurePoint(null).catchError((_) {});
    setState(() {
      _locked = false;
      _seenFrames = 0;
    });
  }

  String _stamp() => DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;

  /// One CSV per receive session, rewritten as it grows (so a crash or force-quit keeps it).
  Future<void> _saveLog() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _sessionStamp ??= _stamp();
      final f = File('${dir.path}/rx-log-$_sessionStamp.csv');
      await f.writeAsString(_pipe.csv());
      _logPath = f.path;
    } catch (_) {}
  }

  /// Every few seconds: save the log and what the camera currently sees (last 6 snapshots kept).
  Future<void> _saveDiagnostics() async {
    if (_cam == null) return;
    await _saveLog();
    final img = _lastImg;
    if (img == null) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final r = _pipe.lastRect;
      final name = 'snap-${_sessionStamp ?? _stamp()}-${(_snapN++ % 6)}.ppm';
      await File('${dir.path}/$name').writeAsBytes(toPpm(img));
      await File('${dir.path}/snap-info.txt').writeAsString(
        'last=$name t=${_clock.elapsedMilliseconds} buf=$_bufInfo capFps=${_capFps.toStringAsFixed(1)} '
        'procMs=${_procMs.toStringAsFixed(1)} agree=${_pipe.acceptor.agree} rect=$r cells=${_pipe.lastCells} '
        'config=${_pipe.receiver.config} locked=$_locked accepted=${_pipe.accepted} headers=${_pipe.receiver.stats.headers}\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  Future<void> _switchLens(int i) async {
    await _stopCamera();
    setState(() => _lens = i);
    await _startCamera();
  }

  void _reset() {
    _saveLog();
    _sessionStamp = null;
    setState(() {
      _newPipeline();
      _status = 'Looking for a sender…';
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _stopCamera();
    } else if (state == AppLifecycleState.resumed && _cam == null) {
      _startCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _diagTimer?.cancel();
    _saveLog();
    _stopCamera();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cam = _cam;
    final s = _pipe.receiver.stats;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Receive'),
        actions: [
          IconButton(tooltip: 'Start over', onPressed: _reset, icon: const Icon(Icons.restart_alt)),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: _error != null
                  ? Container(height: 240, color: kCard, padding: const EdgeInsets.all(16), child: Center(child: Text(_error!, textAlign: TextAlign.center)))
                  : (cam == null || !cam.value.isInitialized)
                      ? Container(height: 240, color: kCard, child: const Center(child: CircularProgressIndicator()))
                      : AspectRatio(
                          aspectRatio: 1 / cam.value.aspectRatio,
                          child: Stack(fit: StackFit.expand, children: [
                            CameraPreview(cam),
                            CustomPaint(painter: _OverlayPainter(_rect, _imgW, _imgH)),
                            Positioned(right: 8, top: 8, child: _CellsView(_cells)),
                            if (_locked)
                              const Positioned(left: 8, top: 8, child: _Chip(icon: Icons.lock, text: 'Exposure locked')),
                          ]),
                        ),
            ),
            const SizedBox(height: 12),
            Text(_status, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _total > 0 ? _solved / _total : 0, minHeight: 8, borderRadius: BorderRadius.circular(4)),
            if (_result != null) ...[
              const SizedBox(height: 12),
              _ResultCard(_result!),
            ],
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _Stat('${_pipe.accepted}', 'frames read'),
              _Stat('${s.headers}', 'headers'),
              _Stat('${s.chunksAdded}', 'chunks ok'),
              _Stat('${s.blocksBad}', 'bad blocks'),
              _Stat('${s.lostFrames}', 'frames missed'),
              _Stat(_capFps.toStringAsFixed(0), 'camera fps'),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _locked ? _unlockExposure : _lockExposure,
                  icon: Icon(_locked ? Icons.lock_open : Icons.lock),
                  label: Text(_locked ? 'Unlock exposure' : 'Lock exposure'),
                ),
              ),
            ]),
            if (_backs.length > 1) ...[
              const SizedBox(height: 12),
              const Text('LENS', style: TextStyle(color: kMuted, fontSize: 13, letterSpacing: 1.2)),
              const SizedBox(height: 6),
              Wrap(spacing: 8, children: [
                for (var i = 0; i < _backs.length; i++)
                  ChoiceChip(label: Text(_lensName(_backs[i], i)), selected: i == _lens, onSelected: (_) => _switchLens(i)),
              ]),
            ],
            const SizedBox(height: 16),
            Text(
              'Point the camera at the sender so its screen is the brightest thing in view and fills a good part of '
              'the yellow box. Hold steady. Further away, use the zoom lens if you have one.'
              '${_logPath != null ? '\n\nLog saved to Files › On My iPhone › Distance Bits.' : ''}',
              style: const TextStyle(color: kMuted, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 8),
            const Text('The sender’s screen flashes rapidly. If you’re sensitive to flashing light, look at this screen instead.',
                style: TextStyle(color: kMuted, fontSize: 13, height: 1.4)),
          ],
        ),
      ),
    );
  }

  String _lensName(CameraDescription d, int i) {
    final n = d.name.toLowerCase();
    if (n.contains('telephoto') || d.lensType == CameraLensType.telephoto) return 'Zoom';
    if (n.contains('ultra') || d.lensType == CameraLensType.ultraWide) return 'Ultra wide';
    if (d.lensType == CameraLensType.wide || i == 0) return 'Main';
    return 'Camera ${i + 1}';
  }
}

class _OverlayPainter extends CustomPainter {
  final ScreenRect? rect;
  final int w, h;
  _OverlayPainter(this.rect, this.w, this.h);
  @override
  void paint(Canvas canvas, Size size) {
    final r = rect;
    if (r == null) return;
    final sx = size.width / w, sy = size.height / h;
    canvas.drawRect(
      Rect.fromLTWH(r.x * sx, r.y * sy, r.w * sx, r.h * sy),
      Paint()
        ..color = kAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_OverlayPainter o) => o.rect != rect;
}

class _CellsView extends StatelessWidget {
  final List<int?> cells;
  const _CellsView(this.cells);
  @override
  Widget build(BuildContext context) {
    if (cells.length != 8) return const SizedBox();
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (var r = 0; r < 4; r++)
          Row(mainAxisSize: MainAxisSize.min, children: [
            for (var c = 0; c < 2; c++)
              Container(
                width: 12,
                height: 12,
                margin: const EdgeInsets.all(1),
                color: cells[r * 2 + c] == null ? Colors.grey.shade700 : _cellColors[cells[r * 2 + c]!],
              ),
          ]),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Chip({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 14, color: kAccent), const SizedBox(width: 4), Text(text, style: const TextStyle(fontSize: 12))]),
      );
}

class _Stat extends StatelessWidget {
  final String value, label;
  const _Stat(this.value, this.label);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          Text(label, style: const TextStyle(color: kMuted, fontSize: 11)),
        ]),
      );
}

class _ResultCard extends StatelessWidget {
  final Payload p;
  const _ResultCard(this.p);
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(border: Border.all(color: kOk), borderRadius: BorderRadius.circular(14)),
      child: switch (p.type) {
        PayloadType.text => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: SelectableText(p.text, style: const TextStyle(fontSize: 20))),
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: p.text));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
              },
            ),
          ]),
        PayloadType.image => Image.memory(p.data),
        PayloadType.file => Text('File: ${p.text} (${p.data.length} bytes)'),
      },
    );
  }
}
