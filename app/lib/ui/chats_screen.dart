import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/store.dart';
import '../core/core.dart';
import 'chat_screen.dart';
import 'diagnostics.dart';
import 'theme.dart';

/// Home: every conversation, most recent first, with the Open channel on top.
class ChatsScreen extends StatelessWidget {
  const ChatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = ChatStore.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final chats = store.sortedChats;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Distance Bits', style: TextStyle(fontWeight: FontWeight.w700)),
            actions: [
              IconButton(icon: const Icon(Icons.info_outline), onPressed: () => _about(context)),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => showModalBottomSheet<void>(context: context, backgroundColor: kCard, builder: (_) => const SettingsSheet()),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            backgroundColor: kAccent,
            foregroundColor: Colors.black,
            icon: const Icon(Icons.add),
            label: const Text('New chat'),
            onPressed: () async {
              final chat = await showModalBottomSheet<Chat>(
                context: context,
                isScrollControlled: true,
                backgroundColor: kCard,
                builder: (_) => const NewChatSheet(),
              );
              if (chat != null && context.mounted) {
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id)));
              }
            },
          ),
          body: !store.loaded
              ? const Center(child: CircularProgressIndicator())
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: chats.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, indent: 76, color: Color(0xFF222226)),
                  itemBuilder: (context, i) => _ChatTile(chat: chats[i]),
                ),
        );
      },
    );
  }

  void _about(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kCard,
        title: const Text('How it works'),
        content: const Text(
          'One phone flashes the message as a grid of colours; the other reads it with its camera. No Wi‑Fi, '
          'Bluetooth or pairing.\n\n'
          'A chat is a 3-character code you agree with someone in person. Both of you create a chat with the same '
          'code; messages in it are encrypted with that code. The Open channel has no code: anyone nearby can read it.\n\n'
          'Light only goes one way at a time: one of you sends, the other taps Listen. Like a walkie-talkie.\n\n'
          'Safety: the sending screen flashes rapidly, which can trigger seizures in people with photosensitive epilepsy.',
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  }
}

class SettingsSheet extends StatefulWidget {
  const SettingsSheet({super.key});
  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  int? _files;

  @override
  void initState() {
    super.initState();
    _count();
  }

  Future<void> _count() async {
    final n = (await diagnosticFiles()).length;
    if (mounted) setState(() => _files = n);
  }

  @override
  Widget build(BuildContext context) {
    final store = ChatStore.instance;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('Settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
            SwitchListTile(
              value: store.diagnostics,
              activeColor: kAccent,
              title: const Text('Save field-test diagnostics'),
              subtitle: const Text('While listening, saves receive logs and small camera snapshots to this app\'s folder in the Files app, '
                  'for troubleshooting. The snapshots show whatever the camera sees. Nothing leaves the phone.'),
              onChanged: (v) => setState(() => store.setDiagnostics(v)),
            ),
            ListTile(
              enabled: (_files ?? 0) > 0,
              leading: const Icon(Icons.delete_outline),
              title: Text(_files == null ? 'Delete saved diagnostics' : 'Delete saved diagnostics ($_files files)'),
              onTap: () async {
                await deleteDiagnostics();
                await _count();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  final Chat chat;
  const _ChatTile({required this.chat});

  @override
  Widget build(BuildContext context) {
    final last = ChatStore.instance.lastMessage(chat.id);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: chat.isOpen ? const Color(0xFF2A2A30) : kAccent.withValues(alpha: 0.18),
        child: chat.isOpen
            ? const Icon(Icons.wifi_tethering, color: kMuted)
            : Text(chat.code, style: const TextStyle(color: kAccent, fontWeight: FontWeight.w700, fontSize: 13, letterSpacing: 1)),
      ),
      title: Text(chat.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
      subtitle: Text(
        last == null ? (chat.isOpen ? 'No code · anyone nearby can read' : 'Code ${chat.code} · no messages yet') : '${last.outgoing ? 'You: ' : ''}${last.text}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: kMuted),
      ),
      trailing: last == null ? null : Text(shortTime(last.at), style: const TextStyle(color: kMuted, fontSize: 12)),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id))),
    );
  }
}

String shortTime(DateTime t) {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${t.hour % 12 == 0 ? 12 : t.hour % 12}:${two(t.minute)} ${t.hour < 12 ? 'AM' : 'PM'}';
  if (now.year == t.year && now.month == t.month && now.day == t.day) return hm;
  return '${t.month}/${t.day}';
}

/// Create a chat: agree a code with the other person, give it a name.
class NewChatSheet extends StatefulWidget {
  const NewChatSheet({super.key});
  @override
  State<NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends State<NewChatSheet> {
  final _code = TextEditingController();
  final _name = TextEditingController();

  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O, 1/I: easier to say out loud

  void _random() {
    final r = Random.secure();
    _code.text = List.generate(3, (_) => _alphabet[r.nextInt(_alphabet.length)]).join();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final valid = isValidCode(_code.text);
    final existing = valid ? ChatStore.instance.chatByCode(_code.text) : null;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('New chat', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        const Text(
          'Agree a 3-character code with the other person, face to face. You both create a chat with the same code. '
          'Only phones with the code can read the messages.',
          style: TextStyle(color: kMuted, height: 1.35),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _code,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              maxLength: 3,
              style: const TextStyle(fontSize: 28, letterSpacing: 8, fontWeight: FontWeight.w700),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
                TextInputFormatter.withFunction((o, n) => n.copyWith(text: n.text.toUpperCase())),
              ],
              decoration: const InputDecoration(labelText: 'Code', counterText: ''),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(onPressed: _random, icon: const Icon(Icons.casino_outlined), label: const Text('Random')),
        ]),
        const SizedBox(height: 12),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Name (optional), e.g. Dave or Campsite'),
        ),
        if (existing != null) ...[
          const SizedBox(height: 8),
          Text('You already have a chat with this code: “${existing.name}”. It will open that one.', style: const TextStyle(color: kAccent)),
        ],
        const SizedBox(height: 18),
        FilledButton(
          onPressed: valid ? () => Navigator.pop(context, ChatStore.instance.createChat(_code.text, _name.text)) : null,
          child: Text(existing != null ? 'Open chat' : 'Create chat'),
        ),
      ]),
    );
  }
}
