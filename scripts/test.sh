#!/bin/bash
# Runs the test suite. With only the Command Line Tools installed (no Xcode), Swift Testing
# lives outside the default search paths, so point the compiler and linker at it.
set -euo pipefail
cd "$(dirname "$0")/.."

EXTRA=()
CLT_FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [ -d "$CLT_FRAMEWORKS/Testing.framework" ] && ! xcode-select -p 2>/dev/null | grep -q Xcode.app; then
  EXTRA=(-Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS" -Xlinker -F -Xlinker "$CLT_FRAMEWORKS"
         -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS"
         # Some CLT releases ship _Testing_Foundation without its module; skip that overlay.
         -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays)
fi

swift test ${EXTRA[@]+"${EXTRA[@]}"} "$@"
