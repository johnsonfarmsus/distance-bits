import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:distance_bits/core/core.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List hex(String s) => Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
String toHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final v = jsonDecode(File('test/crypto_vectors.json').readAsStringSync()) as Map<String, dynamic>;

  test('key derivation and AES-CTR match Node crypto (known answers)', () {
    expect(v['salt'], kdfSalt);
    expect(v['iterations'], kdfIterations);
    for (final c in v['cases'] as List) {
      final key = deriveKey(c['code'] as String);
      expect(toHex(key), c['key']);
      final wire = sealPayload(key, hex(c['plaintext'] as String), nonce: hex(c['nonce'] as String));
      expect(toHex(wire), '${c['nonce']}${c['ciphertext']}');
      expect(toHex(openPayload(key, wire)!), c['plaintext']);
    }
  });

  test('codes: 3 letters/digits, case-insensitive', () {
    expect(isValidCode('k7q'), isTrue);
    expect(isValidCode('AB'), isFalse);
    expect(isValidCode('AB!'), isFalse);
    expect(toHex(deriveKey('k7q')), toHex(deriveKey('K7Q')));
  });

  ({String? text, bool locked}) sendOverLight(String sendCode, String? receiveCode, String text) {
    final cfg = defaultConfig(PresetName.near);
    final wire = sealPayload(deriveKey(sendCode), encodePayload(Payload.text(text)));
    final tx = Transmitter(cfg, wire, msgId: 5, flags: flagEncrypted);
    final rxKey = receiveCode == null ? null : deriveKey(receiveCode);
    String? got;
    var locked = false;
    final rx = Receiver(
      events: ReceiverEvents(onDone: (p, _, __) => got = p.text, onLocked: (_, __) => locked = true),
      unwrap: rxKey == null ? null : (w, _) => openPayload(rxKey, w),
    );
    for (var i = 0; i < 3000 && got == null && !locked; i++) {
      final f = tx.next();
      final p = presets[cfg.preset]!;
      rx.observe(Observation(f.seq * framePeriodMs(cfg.fps), f.layout == Layout.blob ? List.filled(p.cols * p.rows, f.cells[0]) : f.cells));
    }
    return (text: got, locked: locked);
  }

  test('encrypted message decodes with the right code', () {
    expect(sendOverLight('K7Q', 'k7q', 'meet at the gate').text, 'meet at the gate');
  });

  test('wrong code or no code: reported as locked, never shown', () {
    final wrong = sendOverLight('K7Q', 'K7R', 'secret');
    expect(wrong.text, isNull);
    expect(wrong.locked, isTrue);
    final none = sendOverLight('K7Q', null, 'secret');
    expect(none.text, isNull);
    expect(none.locked, isTrue);
  });
}
