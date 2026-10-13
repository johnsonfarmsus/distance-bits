import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/core.dart';

/// A conversation. Coded chats encrypt with their 3-character code; the Open
/// channel has no code and anyone nearby can read it.
class Chat {
  final String id;
  final String code; // '' for the Open channel
  String name;
  PresetName preset;
  PaletteName palette;
  final DateTime created;

  Chat({required this.id, required this.code, required this.name, this.preset = PresetName.near, this.palette = PaletteName.rgbw, DateTime? created})
      : created = created ?? DateTime.now();

  bool get isOpen => code.isEmpty;
  Config get config => Config(preset, palette, defaultConfig(preset).fps);

  Map<String, dynamic> toJson() => {'id': id, 'code': code, 'name': name, 'preset': preset.name, 'palette': palette.name, 'created': created.toIso8601String()};
  factory Chat.fromJson(Map<String, dynamic> j) => Chat(
        id: j['id'] as String,
        code: j['code'] as String,
        name: j['name'] as String,
        preset: PresetName.values.byName(j['preset'] as String),
        palette: PaletteName.values.byName(j['palette'] as String),
        created: DateTime.parse(j['created'] as String),
      );
}

enum MsgStatus { sending, sent, delivered, received }

class Message {
  final String id;
  final bool outgoing;
  final String text;
  final DateTime at;
  MsgStatus status;

  /// Wire message id (random per send), used to drop repeat receptions.
  final int msgId;

  Message({required this.id, required this.outgoing, required this.text, required this.at, required this.status, required this.msgId});

  Map<String, dynamic> toJson() => {'id': id, 'out': outgoing, 'text': text, 'at': at.toIso8601String(), 'status': status.name, 'msgId': msgId};
  factory Message.fromJson(Map<String, dynamic> j) => Message(
        id: j['id'] as String,
        outgoing: j['out'] as bool,
        text: j['text'] as String,
        at: DateTime.parse(j['at'] as String),
        status: MsgStatus.values.byName(j['status'] as String),
        msgId: j['msgId'] as int,
      );
}

const String openChatId = 'open';
const int maxMessagesPerChat = 500;

String _newId() => '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${Random().nextInt(1 << 20).toRadixString(36)}';

/// Chats, their history and app settings, kept in one JSON file in the app's
/// private Application Support folder. (Documents is visible in the Files app;
/// only the optional field-test diagnostics go there.)
class ChatStore extends ChangeNotifier {
  ChatStore._();
  static final ChatStore instance = ChatStore._();

  final List<Chat> chats = [];
  final Map<String, List<Message>> _messages = {};
  final Map<String, Uint8List> _keys = {};
  File? _file;
  Timer? _saveTimer;
  bool loaded = false;

  /// Save receive logs and camera frames to Documents for field testing. Off by
  /// default: the frames are pictures of whatever the camera was pointed at.
  bool diagnostics = false;

  void setDiagnostics(bool on) {
    diagnostics = on;
    _changed();
  }

  Future<void> load() async {
    if (loaded) return;
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    _file = File('${dir.path}/chats.json');
    // Builds before 13 Oct 2026 kept chats.json in Documents (visible in Files).
    try {
      final old = File('${(await getApplicationDocumentsDirectory()).path}/chats.json');
      if (await old.exists() && !await _file!.exists()) await old.copy(_file!.path);
      if (await old.exists()) await old.delete();
    } catch (_) {}
    try {
      if (await _file!.exists()) {
        final j = jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
        for (final c in j['chats'] as List) {
          chats.add(Chat.fromJson(Map<String, dynamic>.from(c as Map)));
        }
        diagnostics = (j['settings'] as Map?)?['diagnostics'] == true;
        (j['messages'] as Map<String, dynamic>).forEach((k, v) {
          _messages[k] = [for (final m in v as List) Message.fromJson(Map<String, dynamic>.from(m as Map))];
        });
      }
    } catch (_) {
      // A corrupt file shouldn't brick the app; start fresh (the old file is kept aside).
      await _file!.rename('${_file!.path}.bad-${DateTime.now().millisecondsSinceEpoch}').catchError((_) => _file!);
    }
    if (!chats.any((c) => c.id == openChatId)) {
      chats.insert(0, Chat(id: openChatId, code: '', name: 'Open channel'));
    }
    // A send interrupted by the app closing is as sent as it will get.
    for (final list in _messages.values) {
      for (final m in list) {
        if (m.status == MsgStatus.sending) m.status = MsgStatus.sent;
      }
    }
    loaded = true;
    notifyListeners();
    for (final c in chats) {
      if (!c.isOpen) keyFor(c);
    }
  }

  void _changed() {
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), save);
  }

  Future<void> save() async {
    final f = _file;
    if (f == null) return;
    final j = {
      'settings': {'diagnostics': diagnostics},
      'chats': [for (final c in chats) c.toJson()],
      'messages': {for (final e in _messages.entries) e.key: [for (final m in e.value) m.toJson()]},
    };
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(j));
    await tmp.rename(f.path);
  }

  Chat? chat(String id) => chats.where((c) => c.id == id).firstOrNull;
  Chat? chatByCode(String code) => chats.where((c) => c.code == normalizeCode(code)).firstOrNull;

  List<Message> messages(String chatId) => _messages[chatId] ?? const [];
  Message? lastMessage(String chatId) => messages(chatId).lastOrNull;

  /// Chats sorted by most recent activity, Open channel first.
  List<Chat> get sortedChats {
    DateTime last(Chat c) => lastMessage(c.id)?.at ?? c.created;
    final coded = chats.where((c) => !c.isOpen).toList()..sort((a, b) => last(b).compareTo(last(a)));
    return [...chats.where((c) => c.isOpen), ...coded];
  }

  Chat createChat(String code, String name) {
    final n = normalizeCode(code);
    final existing = chatByCode(n);
    if (existing != null) return existing;
    final c = Chat(id: _newId(), code: n, name: name.trim().isEmpty ? 'Chat $n' : name.trim());
    chats.add(c);
    keyFor(c);
    _changed();
    return c;
  }

  void updateChat(Chat c) => _changed();

  void deleteChat(String id) {
    if (id == openChatId) return;
    chats.removeWhere((c) => c.id == id);
    _messages.remove(id);
    _changed();
  }

  void clearChat(String id) {
    _messages.remove(id);
    _changed();
  }

  Message addOutgoing(String chatId, String text, int msgId) {
    final m = Message(id: _newId(), outgoing: true, text: text, at: DateTime.now(), status: MsgStatus.sending, msgId: msgId);
    _append(chatId, m);
    return m;
  }

  void markSent(Message m, {bool delivered = false}) {
    // Once confirmed, a later unconfirmed resend doesn't take the tick away.
    if (m.status != MsgStatus.delivered) m.status = delivered ? MsgStatus.delivered : MsgStatus.sent;
    _changed();
  }

  /// Adds a received message unless it's a repeat of one already received
  /// (the sender loops, so the same message can be caught more than once).
  /// Returns null for a repeat.
  Message? addIncoming(String chatId, String text, int msgId) {
    final recent = messages(chatId).reversed.take(20);
    final now = DateTime.now();
    if (recent.any((m) => !m.outgoing && m.msgId == msgId && m.text == text && now.difference(m.at).inHours < 6)) return null;
    final m = Message(id: _newId(), outgoing: false, text: text, at: now, status: MsgStatus.received, msgId: msgId);
    _append(chatId, m);
    return m;
  }

  void deleteMessage(String chatId, Message m) {
    _messages[chatId]?.remove(m);
    _changed();
  }

  void _append(String chatId, Message m) {
    final list = _messages.putIfAbsent(chatId, () => []);
    list.add(m);
    if (list.length > maxMessagesPerChat) list.removeRange(0, list.length - maxMessagesPerChat);
    _changed();
  }

  // ---- keys ----

  /// The chat's key if derived already; starts deriving it in the background otherwise.
  Uint8List? keyFor(Chat c) {
    if (c.isOpen) return null;
    final k = _keys[c.code];
    if (k != null) return k;
    if (!_deriving.contains(c.code)) {
      _deriving.add(c.code);
      compute(deriveKey, c.code).then((key) {
        _keys[c.code] = key;
        _deriving.remove(c.code);
        notifyListeners();
      });
    }
    return null;
  }

  final Set<String> _deriving = {};

  Future<Uint8List> keyForAsync(Chat c) async {
    final k = _keys[c.code];
    if (k != null) return k;
    final key = await compute(deriveKey, c.code);
    _keys[c.code] = key;
    return key;
  }

  /// Every coded chat whose key is ready, current chat first.
  List<(Chat, Uint8List)> keyring({String? preferChatId}) {
    final out = <(Chat, Uint8List)>[];
    for (final c in chats) {
      final k = _keys[c.code];
      if (!c.isOpen && k != null) {
        if (c.id == preferChatId) {
          out.insert(0, (c, k));
        } else {
          out.add((c, k));
        }
      }
    }
    return out;
  }
}
