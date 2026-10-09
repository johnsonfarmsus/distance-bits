import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/core.dart';
import 'receive_screen.dart';
import 'theme.dart';

/// Shown once a message has been decoded: the camera is already off.
class ReceivedScreen extends StatelessWidget {
  final Payload payload;
  final String details;
  const ReceivedScreen({super.key, required this.payload, required this.details});

  @override
  Widget build(BuildContext context) {
    final isText = payload.type == PayloadType.text;
    return Scaffold(
      appBar: AppBar(title: const Text('Message received')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(children: [
                Icon(Icons.check_circle, color: kOk, size: 28),
                SizedBox(width: 8),
                Text('Received', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: kOk)),
              ]),
              const SizedBox(height: 14),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(16), border: Border.all(color: kOk.withValues(alpha: 0.6))),
                  child: SingleChildScrollView(
                    child: switch (payload.type) {
                      PayloadType.text => SelectableText(payload.text, style: const TextStyle(fontSize: 26, height: 1.35)),
                      PayloadType.image => Image.memory(payload.data),
                      PayloadType.file => Text('File: ${payload.text}\n${payload.data.length} bytes', style: const TextStyle(fontSize: 20)),
                    },
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(details, style: const TextStyle(color: kMuted, fontSize: 13)),
              const SizedBox(height: 4),
              const Text('The sender keeps flashing until you tap its screen.', style: TextStyle(color: kMuted, fontSize: 13)),
              const SizedBox(height: 14),
              if (isText)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy message'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: payload.text));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
                  },
                ),
              const SizedBox(height: 10),
              FilledButton.icon(
                icon: const Icon(Icons.camera_alt),
                label: const Text('Receive another'),
                onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const ReceiveScreen())),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
