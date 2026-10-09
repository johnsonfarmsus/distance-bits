import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/core.dart';
import 'image_convert.dart';
import 'screen_exposure.dart';
import 'theme.dart';

const _cellColors = [Color(0xFF000000), Color(0xFFFFFFFF), Color(0xFFFF3333), Color(0xFF33FF33), Color(0xFF3355FF)];

String describeConfig(Config c) {
  const names = {PresetName.near: 'Near', PresetName.mid: 'Mid', PresetName.far: 'Far'};
  const cols = {PaletteName.rgbw: '4 colours', PaletteName.rgw: '3 colours', PaletteName.wr: '2 colours'};
  return '${names[c.preset]} · ${cols[c.palette]}';
}

/// Camera receiver shown at the top of a chat while listening. It finds the
/// sender's screen, decodes, and reports the message once; the chat closes it.
class ListenPanel extends StatefulWidget {
  /// Opens encrypted wire bytes (returns the payload container, or null).
  final Uint8List? Function(Uint8List wire, Header h)? unwrap;
  final void Function(Payload payload, Header h) onReceived;
  final void Function(Header h)? onLocked;
  final VoidCallback onClose;
  const ListenPanel({super.key, this.unwrap, required this.onReceived, this.onLocked, required this.onClose});

  @override
  State<ListenPanel> createState() => _ListenPanelState();
}

class _ListenPanelState extends State<ListenPanel> with WidgetsBindingObserver {
  CameraController? _cam;
  List<CameraDescription> _backs = [];
  int _lens = 0;
  String? _error;

  late RxPipeline _pipe;
  final Stopwatch _clock = Stopwatch()..start();
  bool _busy = false, _finished = false, _showDetails = false;
  int _lastUi = 0;

  String _status = 'Looking for a sender…';
  int _solved = 0, _total = 0;

  ScreenRect? _rect;
  int _imgW = 1, _imgH = 1;
  List<int?> _cells = const [];

  ScreenExposure? _exposure;

  // Diagnostics: saved every few seconds to Documents (log + what the camera sees).
  double _capFps = 0, _lastCapT = -1, _procMs = 0;
  String _bufInfo = '';
  RgbaImage? _lastImg;
  Timer? _diagTimer;
  int _snapN = 0;
  String? _sessionStamp;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _pipe = RxPipeline(
      unwrap: widget.unwrap,
      onConfig: (c, s) => _status = 'Sender found · ${describeConfig(c)}',
      onHeader: (h) => _status = 'Receiving…',
      onProgress: (a, b, _) {
        _solved = a;
        _total = b;
      },
      onCrcFail: (_, __) => _status = 'A bad read slipped through; starting over…',
      onLocked: (_, h) {
        _status = 'Hearing a message for a different code';
        widget.onLocked?.call(h);
      },
      onDone: (p, bytes, h) {
        if (_finished) return;
        _finished = true;
        Future.microtask(() async {
          HapticFeedback.heavyImpact();
          await _saveLog();
          await _stopCamera();
          widget.onReceived(p, h);
        });
      },
    );
    _startCamera();
    _diagTimer = Timer.periodic(const Duration(seconds: 3), (_) => _saveDiagnostics());
  }

  Future<void> _startCamera() async {
    try {
      final all = await availableCameras();
      _backs = all.where((c) => c.lensDirection == CameraLensDirection.back).toList();
      if (_backs.isEmpty) throw 'No rear camera found';
      if (_lens >= _backs.length) _lens = 0;
      // 120 fps where supported: a phone screen redraws top to bottom over a whole
      // refresh, so with ~4 shots per transmitted frame two clean matching shots are the norm.
      CameraController make(int fps) => CameraController(
            _backs[_lens],
            ResolutionPreset.high,
            enableAudio: false,
            fps: fps,
            imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420,
          );
      var cam = make(120);
      try {
        await cam.initialize();
      } catch (_) {
        await cam.dispose();
        cam = make(60);
        await cam.initialize();
      }
      await cam.lockCaptureOrientation(DeviceOrientation.portraitUp).catchError((_) {});
      await cam.setFocusMode(FocusMode.auto).catchError((_) {});
      _cam = cam;
      _exposure = ScreenExposure(_backs[_lens].name);
      await _exposure!.start();
      await cam.startImageStream(_onImage);
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = 'Camera unavailable: $e\nAllow camera access in Settings › Distance Bits.');
    }
  }

  Future<void> _stopCamera() async {
    final cam = _cam;
    _cam = null;
    if (cam == null) return;
    await _exposure?.release();
    try {
      if (cam.value.isStreamingImages) await cam.stopImageStream();
    } catch (_) {}
    await cam.dispose();
  }

  void _onImage(CameraImage img) {
    if (_busy || _finished) return;
    _busy = true;
    try {
      final t = _clock.elapsedMicroseconds / 1000.0;
      if (_lastCapT >= 0 && t > _lastCapT) {
        final f = 1000 / (t - _lastCapT);
        _capFps = _capFps == 0 ? f : _capFps * 0.95 + f * 0.05;
      }
      _lastCapT = t;
      final frame = CamFrame(img, _backs[_lens].sensorOrientation);
      if (!frame.supported) return;
      // Find the screen on a ~240 px copy; read colours at full resolution.
      final step = frame.coarseStep(240);
      final rgba = frame.coarse(240);
      _bufInfo = '${img.width}x${img.height} rot ${frame.rot} step $step';
      _lastImg = rgba;
      final txFps = _pipe.receiver.config?.fps ?? 30;
      _pipe.acceptor.agree = _capFps >= txFps * 1.7 ? 2 : 1;
      _pipe.process(rgba, t, sampler: (r, cols, rows) => frame.sampleCells(ScreenRect(r.x * step, r.y * step, r.w * step, r.h * step), cols, rows));
      _procMs = _procMs * 0.9 + ((_clock.elapsedMicroseconds / 1000.0) - t) * 0.1;
      _rect = _pipe.lastRect;
      _imgW = rgba.width;
      _imgH = rgba.height;
      _cells = _pipe.lastCells;
      double? brightest;
      if (_rect != null) {
        brightest = 0;
        for (final (r, g, b) in _pipe.lastSamples) {
          if (r > brightest!) brightest = r;
          if (g > brightest) brightest = g;
          if (b > brightest) brightest = b;
        }
      }
      _exposure?.update(brightest, t);
      final now = _clock.elapsedMilliseconds;
      if (now - _lastUi > 100 && mounted) {
        _lastUi = now;
        setState(() {});
      }
    } finally {
      _busy = false;
    }
  }

  String _stamp() => DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;

  Future<void> _saveLog() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _sessionStamp ??= _stamp();
      await File('${dir.path}/rx-log-$_sessionStamp.csv').writeAsString(_pipe.csv());
    } catch (_) {}
  }

  Future<void> _saveDiagnostics() async {
    if (_cam == null) return;
    await _saveLog();
    final img = _lastImg;
    if (img == null) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final name = 'snap-${_sessionStamp ?? _stamp()}-${_snapN++ % 6}.ppm';
      await File('${dir.path}/$name').writeAsBytes(toPpm(img));
      await File('${dir.path}/snap-info.txt').writeAsString(
        'last=$name t=${_clock.elapsedMilliseconds} buf=$_bufInfo capFps=${_capFps.toStringAsFixed(1)} '
        'procMs=${_procMs.toStringAsFixed(1)} agree=${_pipe.acceptor.agree} rect=${_pipe.lastRect} '
        'config=${_pipe.receiver.config} exposure=${_exposure?.label} accepted=${_pipe.accepted} headers=${_pipe.receiver.stats.headers}\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  Future<void> _switchLens(int i) async {
    await _stopCamera();
    setState(() => _lens = i);
    await _startCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _stopCamera();
    } else if (state == AppLifecycleState.resumed && _cam == null && !_finished) {
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

  String _lensName(CameraDescription d, int i) {
    final n = d.name.toLowerCase();
    if (n.contains('telephoto') || d.lensType == CameraLensType.telephoto) return 'Zoom';
    if (n.contains('ultra') || d.lensType == CameraLensType.ultraWide) return 'Ultra wide';
    if (d.lensType == CameraLensType.wide || i == 0) return 'Main';
    return 'Camera ${i + 1}';
  }

  @override
  Widget build(BuildContext context) {
    final cam = _cam;
    final s = _pipe.receiver.stats;
    final previewH = MediaQuery.of(context).size.height * 0.30;
    return Container(
      color: kCard,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: previewH,
          child: Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _error != null
                  ? Padding(padding: const EdgeInsets.all(12), child: Text(_error!, textAlign: TextAlign.center))
                  : (cam == null || !cam.value.isInitialized)
                      ? const SizedBox(width: 60, height: 60, child: Center(child: CircularProgressIndicator()))
                      : AspectRatio(
                          aspectRatio: 1 / cam.value.aspectRatio,
                          child: Stack(fit: StackFit.expand, children: [
                            CameraPreview(cam),
                            CustomPaint(painter: _OverlayPainter(_rect, _imgW, _imgH)),
                            Positioned(right: 4, top: 4, child: _CellsView(_cells)),
                          ]),
                        ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          if (_status == 'Looking for a sender…')
            const Padding(padding: EdgeInsets.only(right: 8), child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))),
          Expanded(child: Text(_status, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Details',
            onPressed: () => setState(() => _showDetails = !_showDetails),
            icon: Icon(_showDetails ? Icons.expand_less : Icons.tune, size: 20),
          ),
          TextButton(onPressed: widget.onClose, child: const Text('Stop')),
        ]),
        LinearProgressIndicator(value: _total > 0 ? _solved / _total : 0, minHeight: 6, borderRadius: BorderRadius.circular(3)),
        if (_showDetails) ...[
          const SizedBox(height: 6),
          Text(
            'camera ${_capFps.toStringAsFixed(0)} fps · ${_exposure?.label ?? ''} · frames ${_pipe.accepted} · headers ${s.headers} · '
            'chunks ${s.chunksAdded} · bad blocks ${s.blocksBad} · missed ${s.lostFrames}',
            style: const TextStyle(color: kMuted, fontSize: 12),
          ),
          if (_backs.length > 1)
            Wrap(spacing: 6, children: [
              for (var i = 0; i < _backs.length; i++)
                ChoiceChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(_lensName(_backs[i], i)),
                  selected: i == _lens,
                  onSelected: (_) => _switchLens(i),
                ),
            ]),
        ],
      ]),
    );
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
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (var r = 0; r < 4; r++)
          Row(mainAxisSize: MainAxisSize.min, children: [
            for (var c = 0; c < 2; c++)
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.all(1),
                color: cells[r * 2 + c] == null ? Colors.grey.shade700 : _cellColors[cells[r * 2 + c]!],
              ),
          ]),
      ]),
    );
  }
}
