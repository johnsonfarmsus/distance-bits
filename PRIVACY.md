# Privacy

Distance Bits has no servers, accounts, analytics, ads or tracking, and the app
makes no network connections. Messages travel only as light between two phones in
sight of each other.

## What the iPhone app uses

- **Camera:** the rear camera while you're on the Listen screen, to read the other
  phone's screen. The front camera while you're sending, to see the receiver's
  flashlight confirm delivery. Camera frames are processed in memory and discarded.
  They are saved only if you turn on field-test diagnostics (below).
- **Flashlight:** blinks briefly after a message is received, as the delivery
  confirmation.
- **Screen brightness:** turned up while sending, restored afterwards.

## What it stores, on the phone only

- **Chats, their codes and message history** (the last 500 messages per chat), in
  the app's private storage. It is not visible in the Files app, but it is included
  in your device backups like other app data. Deleting the app deletes it.
- **Field-test diagnostics, only if you turn them on** in Settings. These are saved
  while listening to the app's folder in the Files app:
  - a CSV log of what the receiver saw in each capture;
  - small, low-resolution camera snapshots and short bursts of frames.

  The snapshots are pictures of whatever the camera was pointed at. They are for
  troubleshooting range problems and stay on the phone unless you copy them off.
  **Settings › Delete saved diagnostics** removes them.

## Logs in this repository

The test fixtures in `app/test/fixtures/` and `test-data/` are a few low-resolution
frames and logs from the author's own field tests, included so the tests reproduce
real conditions. If you contribute field logs, please look through the snapshots
first.

## Web prototype

The web version (`src/`) runs entirely in your browser. Camera frames never leave
the page, and the receive log is downloaded only when you press the button. The
hosted copy is served by GitHub Pages, which, like any web host, sees your IP
address when you load the page.
