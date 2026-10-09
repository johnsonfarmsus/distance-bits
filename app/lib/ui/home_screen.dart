import 'package:flutter/material.dart';

import 'receive_screen.dart';
import 'send_screen.dart';
import 'theme.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              const Text('Distance Bits', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              const Text('Text over light. No Wi‑Fi, no Bluetooth, no pairing.', style: TextStyle(color: kMuted, fontSize: 16)),
              const Spacer(),
              _BigButton(
                icon: Icons.flashlight_on_outlined,
                title: 'Send',
                subtitle: 'Your screen flashes the message',
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SendScreen())),
              ),
              const SizedBox(height: 14),
              _BigButton(
                icon: Icons.camera_alt_outlined,
                title: 'Receive',
                subtitle: 'Point your camera at the sender',
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ReceiveScreen())),
              ),
              const Spacer(),
              const Text(
                'How it works: one phone flashes a grid of colours, the other reads it with its camera. '
                'Hold both phones upright. Further away? Pick a longer range on the sender: slower, but it reaches further.',
                style: TextStyle(color: kMuted, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  const _BigButton({required this.icon, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kCard,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: kAccent.withValues(alpha: 0.5))),
          child: Row(
            children: [
              Icon(icon, size: 40, color: kAccent),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: const TextStyle(color: kMuted)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: kMuted),
            ],
          ),
        ),
      ),
    );
  }
}
