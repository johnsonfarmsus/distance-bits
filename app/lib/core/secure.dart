import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Chat-code encryption (see PROTOCOL.md, "Encryption").
///
/// Threat model: keep a nearby onlooker running the same app from reading along.
/// It does not authenticate the sender, and a determined attacker with a
/// recording can brute-force a 3-character code given enough compute.
///
///   key     = PBKDF2-HMAC-SHA256(code, "distance-bits/v1", 50 000 iterations, 16 bytes)
///   wire    = nonce(4, random) | AES-128-CTR(key, iv = nonce ‖ 0×12)(payload container)
/// The container's own CRC-16 tells the receiver whether the code was right.

const String kdfSalt = 'distance-bits/v1';
const int kdfIterations = 50000;
const int nonceBytes = 4;

/// Codes are 3 characters, A–Z and 0–9, case-insensitive.
final RegExp codePattern = RegExp(r'^[A-Z0-9]{3}$');

String normalizeCode(String code) => code.trim().toUpperCase();

bool isValidCode(String code) => codePattern.hasMatch(normalizeCode(code));

/// Slow on purpose (~0.2–0.5 s on a phone); derive once per chat and keep it.
Uint8List deriveKey(String code) {
  final kdf = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(Uint8List.fromList(utf8.encode(kdfSalt)), kdfIterations, 16));
  return kdf.process(Uint8List.fromList(utf8.encode(normalizeCode(code))));
}

Uint8List _ctr(Uint8List key, Uint8List nonce, Uint8List input) {
  final iv = Uint8List(16)..setRange(0, nonceBytes, nonce);
  final c = CTRStreamCipher(AESEngine())..init(true, ParametersWithIV(KeyParameter(key), iv));
  return c.process(input);
}

/// Encrypt a payload container for the wire.
Uint8List sealPayload(Uint8List key, Uint8List container, {Uint8List? nonce}) {
  final n = nonce ?? Uint8List.fromList(List.generate(nonceBytes, (_) => Random.secure().nextInt(256)));
  return Uint8List.fromList([...n, ..._ctr(key, n, container)]);
}

/// Decrypt wire bytes back to a container (whether the key was right is up to
/// the container's CRC to say).
Uint8List? openPayload(Uint8List key, Uint8List wire) {
  if (wire.length <= nonceBytes) return null;
  final n = Uint8List.sublistView(wire, 0, nonceBytes);
  return _ctr(key, n, Uint8List.sublistView(wire, nonceBytes));
}
