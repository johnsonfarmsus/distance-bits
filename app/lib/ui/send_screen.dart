import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/core.dart';
import 'safety.dart';
import 'theme.dart';
import 'transmit_screen.dart';

const _rangeLabels = {
  PresetName.near: ('Near', 'up to ~12 m', '2×4 grid'),
  PresetName.mid: ('Mid', '12–25 m', '2 halves'),
  PresetName.far: ('Far', '25–50 m', 'whole screen'),
};

const _paletteLabels = {
  PaletteName.rgbw: ('4 colours', 'fastest'),
  PaletteName.rgw: ('3 colours', 'no blue'),
  PaletteName.wr: ('2 colours', 'most robust'),
};

class SendScreen extends StatefulWidget {
  const SendScreen({super.key});
  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends State<SendScreen> {
  final _text = TextEditingController(text: 'hello from distance bits');
  Config _cfg = defaultConfig(PresetName.near);

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      final t = p.getString('send.text');
      final pr = p.getString('send.preset');
      final pa = p.getString('send.palette');
      if (!mounted) return;
      setState(() {
        if (t != null) _text.text = t;
        if (pr != null) _cfg = defaultConfig(PresetName.values.byName(pr));
        if (pa != null) _cfg = _cfg.copyWith(palette: PaletteName.values.byName(pa));
      });
    });
    _text.addListener(() => setState(() {}));
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('send.text', _text.text);
    await p.setString('send.preset', _cfg.preset.name);
    await p.setString('send.palette', _cfg.palette.name);
  }

  Transmitter _tx() => Transmitter(_cfg, encodePayload(Payload.text(_text.text.isEmpty ? ' ' : _text.text)), msgId: Random().nextInt(256));

  String _estimate() {
    try {
      final tx = _tx();
      final s = tx.estimateSeconds();
      final t = s < 90 ? '${s.round()} s' : '${(s / 60).toStringAsFixed(1)} min';
      return '${tx.payload.length} bytes · about $t on a clean link';
    } catch (e) {
      return 'Message too long';
    }
  }

  Future<void> _send() async {
    FocusScope.of(context).unfocus();
    await _save();
    if (!mounted || !await confirmFlashWarning(context) || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => TransmitScreen(transmitter: _tx())));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            TextField(
              controller: _text,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(hintText: 'Type a message…'),
            ),
            const SizedBox(height: 20),
            const _Label('Distance'),
            SegmentedButton<PresetName>(
              segments: [
                for (final p in PresetName.values)
                  ButtonSegment(value: p, label: Text(_rangeLabels[p]!.$1)),
              ],
              selected: {_cfg.preset},
              onSelectionChanged: (s) => setState(() => _cfg = defaultConfig(s.first)),
            ),
            const SizedBox(height: 6),
            Text('${_rangeLabels[_cfg.preset]!.$2} · ${_rangeLabels[_cfg.preset]!.$3}', style: const TextStyle(color: kMuted)),
            const SizedBox(height: 20),
            const _Label('Colours'),
            SegmentedButton<PaletteName>(
              segments: [
                for (final p in [PaletteName.rgbw, PaletteName.rgw, PaletteName.wr])
                  ButtonSegment(value: p, label: Text(_paletteLabels[p]!.$1)),
              ],
              selected: {_cfg.palette},
              onSelectionChanged: (s) => setState(() => _cfg = _cfg.copyWith(palette: s.first)),
            ),
            const SizedBox(height: 6),
            Text(_paletteLabels[_cfg.palette]!.$2, style: const TextStyle(color: kMuted)),
            const SizedBox(height: 24),
            Text(_estimate(), style: const TextStyle(color: kMuted)),
            const SizedBox(height: 12),
            FilledButton.icon(onPressed: _send, icon: const Icon(Icons.flashlight_on), label: const Text('Send')),
            const SizedBox(height: 16),
            const Text(
              'Your screen goes full brightness and flashes until you tap it. Hold the phone upright with the screen '
              'facing the receiver, as steady as you can.',
              style: TextStyle(color: kMuted, fontSize: 13, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text.toUpperCase(), style: const TextStyle(color: kMuted, fontSize: 13, letterSpacing: 1.2)),
      );
}
