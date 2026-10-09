#!/bin/bash
# Move files dropped into .incoming/ as <name>-<sha1 prefix>.<ext> into place,
# after checking each one's checksum.   usage: place-incoming.sh <incoming-name> <dest> [...]
cd "$(dirname "$0")/.."
ok=0
while [ $# -ge 2 ]; do
  src=".incoming/$1"; dst="$2"; shift 2
  want=$(echo "$src" | sed 's/.*-\([0-9a-f]\{8\}\)\.[A-Za-z]*$/\1/')
  got=$(shasum "$src" 2>/dev/null | cut -c1-8 || sha1sum "$src" 2>/dev/null | cut -c1-8)
  [ -z "$got" ] && got=$(sha1sum "$src" 2>/dev/null | cut -c1-8)
  if [ "$got" = "$want" ]; then mkdir -p "$(dirname "$dst")"; mv -f "$src" "$dst" && echo "ok   $dst"; else echo "FAIL $src (checksum ${got:-missing})"; ok=1; fi
done
exit $ok
