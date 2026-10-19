#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -parse-as-library -module-cache-path build/module-cache Sources/Store.swift Sources/ReadingAppearance.swift tests/ReadingAppearanceV109UIHarness.swift -framework CoreText -framework AppKit -framework WebKit -o build/reading-appearance-v109-ui-tests
build/reading-appearance-v109-ui-tests "$PWD/Resources/ui"
