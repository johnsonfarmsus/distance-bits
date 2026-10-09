import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/store.dart';
import '../core/core.dart';
import 'chats_screen.dart' show shortTime;
import 'listen_panel.dart';
import 'safety.dart';
import 'theme.dart';
import 'transmit_screen.dart';

/// One conversation: bubbles, a composer, and a Listen panel that opens at the top.
class ChatScreen extends StatefulWidget {
  final String chatId;
  const ChatScreen({super.key, required this.chatId});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _store = ChatStore.instance;
  final _composer = TextEditingController();
  bool _listening = false;
  String? _matchedChatId;

  Chat get _chat => _store.chat(widget.chatId)!;

  @override
  void initState() {
    super.initState();
    _composer.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  // ---- sending ----

  Future<void> _send({Message? again}) async {
    final text = again?.text ?? _composer.text.trim();
    if (text.isEmpty) return;
    FocusScope.of(context).unfocus();
    if (!await confirmFlashWarning(context) || !mounted) return;
    final chat = _chat;
    Uint8List bytes = encodePayload(Payload.text(text));
    var flags = 0;
    if (!chat.isOpen) {
      bytes = sealPayload(await _store.keyForAsync(chat), bytes);
      flags = flagEncrypted;
    }
    setState(() => _listening = false);
    // A resend keeps its wire id so a receiver that already has it ignores the repeat.
    final msgId = again?.msgId ?? Random().nextInt(256);
    final Message m;
    if (again != null) {
      m = again..status = MsgStatus.sending;
      _store.updateChat(chat);
    } else {
      m = _store.addOutgoing(chat.id, text, msgId);
      _composer.clear();
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TransmitScreen(transmitter: Transmitter(chat.config, bytes, msgId: msgId, flags: flags)),
    ));
    _store.markSent(m);
  }

  String? _estimate() {
    final text = _composer.text.trim();
    if (text.isEmpty) return null;
    try {
      final n = encodePayload(Payload.text(text)).length + (_chat.isOpen ? 0 : nonceBytes);
      final s = Transmitter(_chat.config, Uint8List(n), msgId: 0).estimateSeconds();
      final t = s < 90 ? '${s.round()} s' : '${(s / 60).toStringAsFixed(1)} min';
      return 'about $t to send · ${describeConfig(_chat.config)}';
    } catch (_) {
      return 'Message too long';
    }
  }

  // ---- receiving ----

  Uint8List? _unwrap(Uint8List wire, Header h) {
    // Try this chat's code first, then every other chat's: a message lands in
    // whichever chat it was sent to.
    for (final (c, key) in _store.keyring(preferChatId: widget.chatId)) {
      final container = openPayload(key, wire);
      if (container != null && decodePayload(container) != null) {
        _matchedChatId = c.id;
        return container;
      }
    }
    return null;
  }

  void _onReceived(Payload p, Header h) {
    final encrypted = h.flags & flagEncrypted != 0;
    final targetId = encrypted ? (_matchedChatId ?? widget.chatId) : openChatId;
    final text = switch (p.type) {
      PayloadType.text => p.text,
      PayloadType.image => '[image, ${p.data.length} bytes]',
      PayloadType.file => '[file: ${p.text}]',
    };
    final added = _store.addIncoming(targetId, text, h.msgId);
    setState(() => _listening = false);
    final messenger = ScaffoldMessenger.of(context);
    if (added == null) {
      messenger.showSnackBar(const SnackBar(content: Text('Got that message already')));
    } else if (targetId != widget.chatId) {
      final target = _store.chat(targetId)!;
      messenger.showSnackBar(SnackBar(
        content: Text('New message in “${target.name}”'),
        action: SnackBarAction(
          label: 'Open',
          onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ChatScreen(chatId: targetId))),
        ),
      ));
    }
  }

  // ---- menus ----

  Future<void> _signalSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCard,
      builder: (_) => _SignalSheet(chat: _chat),
    );
    setState(() {});
  }

  void _messageActions(Message m) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCard,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.copy),
            title: const Text('Copy'),
            onTap: () {
              Clipboard.setData(ClipboardData(text: m.text));
              Navigator.pop(ctx);
            },
          ),
          if (m.outgoing)
            ListTile(
              leading: const Icon(Icons.replay),
              title: const Text('Send again'),
              onTap: () {
                Navigator.pop(ctx);
                _send(again: m);
              },
            ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: kBad),
            title: const Text('Delete', style: TextStyle(color: kBad)),
            onTap: () {
              _store.deleteMessage(widget.chatId, m);
              Navigator.pop(ctx);
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _menu(String action) async {
    if (action == 'clear' || action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: kCard,
          title: Text(action == 'clear' ? 'Clear all messages?' : 'Delete this chat?'),
          content: Text(action == 'clear' ? 'The messages are removed from this phone only.' : 'The chat and its messages are removed from this phone.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action == 'clear' ? 'Clear' : 'Delete', style: const TextStyle(color: kBad))),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      if (action == 'clear') {
        _store.clearChat(widget.chatId);
      } else {
        Navigator.of(context).pop();
        _store.deleteChat(widget.chatId);
      }
    } else if (action == 'rename') {
      final ctl = TextEditingController(text: _chat.name);
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: kCard,
          title: const Text('Rename chat'),
          content: TextField(controller: ctl, autofocus: true, textCapitalization: TextCapitalization.words),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Save')),
          ],
        ),
      );
      if (name != null && name.isNotEmpty) {
        _chat.name = name;
        _store.updateChat(_chat);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final chat = _store.chat(widget.chatId);
        if (chat == null) return const Scaffold();
        final msgs = _store.messages(chat.id);
        final estimate = _estimate();
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(chat.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              Text(chat.isOpen ? 'Open · anyone nearby can read' : 'Code ${chat.code} · encrypted', style: const TextStyle(fontSize: 12, color: kMuted)),
            ]),
            actions: [
              IconButton(tooltip: 'Signal settings', icon: const Icon(Icons.tune), onPressed: _signalSettings),
              PopupMenuButton<String>(
                onSelected: _menu,
                itemBuilder: (_) => [
                  if (!chat.isOpen) const PopupMenuItem(value: 'rename', child: Text('Rename')),
                  const PopupMenuItem(value: 'clear', child: Text('Clear messages')),
                  if (!chat.isOpen) const PopupMenuItem(value: 'delete', child: Text('Delete chat')),
                ],
              ),
            ],
          ),
          body: Column(children: [
            if (_listening)
              ListenPanel(
                key: const ValueKey('listen'),
                unwrap: _unwrap,
                onReceived: _onReceived,
                onClose: () => setState(() => _listening = false),
              ),
            Expanded(
              child: msgs.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                          'No messages yet.\n\nType below and tap send to flash a message, or tap Listen when the other person is sending.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: kMuted, height: 1.4),
                        ),
                      ),
                    )
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                      itemCount: msgs.length,
                      itemBuilder: (context, i) {
                        final m = msgs[msgs.length - 1 - i];
                        return _Bubble(message: m, onLongPress: () => _messageActions(m));
                      },
                    ),
            ),
            _Composer(
              controller: _composer,
              listening: _listening,
              estimate: estimate,
              onListen: () {
                FocusScope.of(context).unfocus(); // the keyboard would cover the chat while listening
                setState(() => _listening = !_listening);
              },
              onSend: _send,
            ),
          ]),
        );
      },
    );
  }
}

class _Bubble extends StatelessWidget {
  final Message message;
  final VoidCallback onLongPress;
  const _Bubble({required this.message, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final out = message.outgoing;
    final meta = [
      shortTime(message.at),
      if (out) message.status == MsgStatus.sending ? 'Sending…' : 'Sent',
    ].join(' · ');
    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Column(crossAxisAlignment: out ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
            GestureDetector(
              onLongPress: onLongPress,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: out ? kAccent : const Color(0xFF26262B),
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(18),
                    topRight: const Radius.circular(18),
                    bottomLeft: Radius.circular(out ? 18 : 4),
                    bottomRight: Radius.circular(out ? 4 : 18),
                  ),
                ),
                child: Text(message.text, style: TextStyle(fontSize: 17, color: out ? Colors.black : Colors.white, height: 1.3)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 6, right: 6),
              child: Text(meta, style: const TextStyle(color: kMuted, fontSize: 11)),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool listening;
  final String? estimate;
  final VoidCallback onListen;
  final VoidCallback onSend;
  const _Composer({required this.controller, required this.listening, required this.estimate, required this.onListen, required this.onSend});

  @override
  Widget build(BuildContext context) {
    final canSend = controller.text.trim().isNotEmpty;
    return Container(
      decoration: const BoxDecoration(color: kBg, border: Border(top: BorderSide(color: Color(0xFF222226)))),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              _RoundButton(
                icon: listening ? Icons.videocam_off_outlined : Icons.camera_alt_outlined,
                label: listening ? 'Stop' : 'Listen',
                filled: listening,
                onTap: onListen,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: 'Message',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                style: IconButton.styleFrom(backgroundColor: kAccent, foregroundColor: Colors.black, disabledBackgroundColor: const Color(0xFF2A2A30)),
                onPressed: canSend ? onSend : null,
                icon: const Icon(Icons.arrow_upward),
              ),
            ]),
            if (estimate != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(estimate!, style: const TextStyle(color: kMuted, fontSize: 11)),
              ),
          ]),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool filled;
  final VoidCallback onTap;
  const _RoundButton({required this.icon, required this.label, required this.filled, required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: filled ? kAccent.withValues(alpha: 0.2) : const Color(0xFF1C1C20),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: filled ? kAccent : const Color(0xFF2A2A30)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 20, color: filled ? kAccent : Colors.white),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: filled ? kAccent : Colors.white, fontWeight: FontWeight.w600)),
          ]),
        ),
      );
}

const _rangeLabels = {
  PresetName.near: ('Near', 'up to ~12 m · 2×4 grid'),
  PresetName.mid: ('Mid', '12–25 m · 2 halves'),
  PresetName.far: ('Far', '25–50 m · whole screen'),
};
const _paletteLabels = {
  PaletteName.rgbw: ('4 colours', 'fastest'),
  PaletteName.rgw: ('3 colours', 'no blue'),
  PaletteName.wr: ('2 colours', 'most robust'),
};

/// Range and colours this chat sends with. The receiver detects them on its own.
class _SignalSheet extends StatefulWidget {
  final Chat chat;
  const _SignalSheet({required this.chat});
  @override
  State<_SignalSheet> createState() => _SignalSheetState();
}

class _SignalSheetState extends State<_SignalSheet> {
  @override
  Widget build(BuildContext context) {
    final c = widget.chat;
    void save() {
      ChatStore.instance.updateChat(c);
      setState(() {});
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Signal settings', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text('How your phone sends in this chat. The other phone figures it out by itself.', style: TextStyle(color: kMuted)),
          const SizedBox(height: 16),
          const Text('DISTANCE', style: TextStyle(color: kMuted, fontSize: 12, letterSpacing: 1.2)),
          const SizedBox(height: 6),
          SegmentedButton<PresetName>(
            segments: [for (final p in PresetName.values) ButtonSegment(value: p, label: Text(_rangeLabels[p]!.$1))],
            selected: {c.preset},
            onSelectionChanged: (s) {
              c.preset = s.first;
              c.palette = defaultConfig(s.first).palette;
              save();
            },
          ),
          const SizedBox(height: 4),
          Text(_rangeLabels[c.preset]!.$2, style: const TextStyle(color: kMuted)),
          const SizedBox(height: 14),
          const Text('COLOURS', style: TextStyle(color: kMuted, fontSize: 12, letterSpacing: 1.2)),
          const SizedBox(height: 6),
          SegmentedButton<PaletteName>(
            segments: [for (final p in [PaletteName.rgbw, PaletteName.rgw, PaletteName.wr]) ButtonSegment(value: p, label: Text(_paletteLabels[p]!.$1))],
            selected: {c.palette},
            onSelectionChanged: (s) {
              c.palette = s.first;
              save();
            },
          ),
          const SizedBox(height: 4),
          Text(_paletteLabels[c.palette]!.$2, style: const TextStyle(color: kMuted)),
          const SizedBox(height: 12),
        ]),
      ),
    );
  }
}
