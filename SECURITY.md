# Security

## What the chat codes protect against

Messages in a coded chat are encrypted with a key derived from the chat's
3-character code (details in [`PROTOCOL.md`](PROTOCOL.md#encryption-chat-codes)).
The goal is narrow: **someone nearby, running this app or anything that speaks the
protocol, shouldn't be able to read your messages just by pointing a camera at
your screen.** The Open channel has no code and no encryption; anyone in view can
read it.

## What they don't protect against

- **A determined attacker with a recording.** There are only 46,656 possible
  codes. Key derivation is deliberately slow (PBKDF2-SHA256, 50,000 iterations), but
  anyone who records a message can still try every code offline. Our estimate is
  under a minute on a laptop and seconds on a GPU. The code keeps out casual
  onlookers; it is not real secrecy.
- **Forgery or tampering.** Messages are not authenticated (AES-CTR with a CRC-16,
  no MAC). Someone who can shine their own screen at your camera could send you
  messages, or alter a message they captured, without knowing the code. The app
  can't prove who sent a message.
- **Seeing the screen itself.** The sender types in plain view. Encryption covers
  the flashing light, not the keyboard.
- **The delivery confirmation.** The flashlight blink that tells the sender
  "received" is not tied to a message or a code. Anyone with a flashlight can fake
  it.

Messages and chat codes are stored unencrypted in the app's private storage on the
phone (see [`PRIVACY.md`](PRIVACY.md)), protected by iOS's normal app sandbox and
device encryption.

If you need confidentiality against a motivated adversary, use something else.

## Reporting a vulnerability

Please use GitHub's private reporting (**Security › Report a vulnerability** on this
repository) rather than a public issue. This is a hobby project with no bounty, but
reports are read and fixed.
