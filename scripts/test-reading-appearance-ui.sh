#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -parse-as-library -module-cache-path build/module-cache tests/ReadingAppearanceUIHarness.swift -framework AppKit -framework WebKit -o build/reading-appearance-ui-tests
build/reading-appearance-ui-tests "$PWD/Resources/ui"
