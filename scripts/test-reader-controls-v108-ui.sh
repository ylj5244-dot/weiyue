#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -parse-as-library -module-cache-path build/module-cache Sources/Store.swift Sources/ReadingAppearance.swift tests/ReaderControlsV108UIHarness.swift -framework AppKit -framework WebKit -framework CoreText -o build/reader-controls-v108-ui-tests
build/reader-controls-v108-ui-tests "$PWD/Resources/ui"
