# Distance Bits app (Flutter)

The iPhone app. See the [project README](../README.md) for what it is, how to build
it, and the state of things; [`PROTOCOL.md`](../PROTOCOL.md) for the protocol.

```
flutter pub get
flutter test                 # unit tests
flutter run --release        # on a connected phone (set your signing team in Xcode first)
```

- `lib/core/`: protocol and vision (pure Dart, no Flutter imports)
- `lib/chat/`: chats, history, settings
- `lib/ui/`: screens
- `ios/Runner/AppDelegate.swift`: native channels for camera exposure, lens
  info, screen brightness and torch
- `test/`: protocol, crypto, ack-detector and vision tests; `fixtures/` holds real
  camera frames from field tests
