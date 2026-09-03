#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

if xcrun --show-sdk-platform-path >/dev/null 2>&1; then
  exec swift test "$@"
fi

FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
exec swift test \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
  -Xlinker -F -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  "$@"
