#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -parse-as-library -module-cache-path build/module-cache Sources/Store.swift tests/ReadingAnchorsUIHarness.swift -framework AppKit -framework WebKit -o build/reading-anchors-ui-tests
build/reading-anchors-ui-tests "$PWD/Resources/ui"
