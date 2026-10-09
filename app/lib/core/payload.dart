import 'dart:convert';
import 'dart:typed_data';

import 'crc.dart';

/// Message container inside the fountain-coded bytes:
///   type(1) | crc16 of body(2) | body
///   0 text : UTF-8 · 1 file : nameLen(1) name data · 2 image : mimeLen(1) mime data
enum PayloadType { text, file, image }

class Payload {
  final PayloadType type;
  final String text; // text: the message; file: name; image: mime
  final Uint8List data; // file/image bytes
  Payload.text(this.text)
      : type = PayloadType.text,
        data = Uint8List(0);
  Payload.file(String name, this.data)
      : type = PayloadType.file,
        text = name;
  Payload.image(String mime, this.data)
      : type = PayloadType.image,
        text = mime;
}

const int maxPayloadBytes = 65535;

Uint8List encodePayload(Payload p) {
  final List<int> body;
  switch (p.type) {
    case PayloadType.text:
      body = utf8.encode(p.text);
    case PayloadType.file:
    case PayloadType.image:
      final name = utf8.encode(p.text);
      final n = name.length > 255 ? name.sublist(0, 255) : name;
      body = [n.length, ...n, ...p.data];
  }
  final crc = crc16(body);
  final out = Uint8List.fromList([p.type.index, crc >> 8, crc & 0xff, ...body]);
  if (out.length > maxPayloadBytes) throw ArgumentError('payload too large: ${out.length} bytes');
  return out;
}

Payload? decodePayload(Uint8List bytes) {
  if (bytes.length < 3) return null;
  final type = bytes[0];
  final crc = (bytes[1] << 8) | bytes[2];
  final body = bytes.sublist(3);
  if (crc16(body) != crc) return null;
  try {
    switch (type) {
      case 0:
        return Payload.text(utf8.decode(body, allowMalformed: true));
      case 1:
        final n = body[0];
        return Payload.file(utf8.decode(body.sublist(1, 1 + n), allowMalformed: true), body.sublist(1 + n));
      case 2:
        final n = body[0];
        return Payload.image(utf8.decode(body.sublist(1, 1 + n), allowMalformed: true), body.sublist(1 + n));
    }
  } catch (_) {
    return null;
  }
  return null;
}
