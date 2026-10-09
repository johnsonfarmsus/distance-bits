import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme.dart';

const _key = 'flash-warning-ok';

/// Photosensitivity warning before sending. Full-screen flashing between saturated
/// colours and black at 3–30 Hz is a known seizure trigger. Returns true to proceed.
Future<bool> confirmFlashWarning(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_key) ?? false) return true;
  if (!context.mounted) return false;
  var remember = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        backgroundColor: kCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: const BorderSide(color: kAccent)),
        title: const Row(children: [Icon(Icons.warning_amber_rounded, color: kAccent), SizedBox(width: 8), Text('Flashing lights')]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Sending makes this screen flash rapidly between bright colours and black. '
                'This can trigger seizures in people with photosensitive epilepsy.'),
            const SizedBox(height: 10),
            const Text('Don’t use it if you or anyone who will see the screen has a history of seizures or is '
                'sensitive to flashing light. Stop at once if anyone feels unwell. Tap the screen to stop.'),
            const SizedBox(height: 6),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: remember,
              onChanged: (v) => setState(() => remember = v ?? false),
              title: const Text('Don’t show this again', style: TextStyle(color: kMuted, fontSize: 14)),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('I understand, send'),
          ),
        ],
      ),
    ),
  );
  if (ok == true && remember) await prefs.setBool(_key, true);
  return ok == true;
}
