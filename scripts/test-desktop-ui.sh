#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -parse-as-library -module-cache-path build/module-cache tests/DesktopUIHarness.swift -framework AppKit -framework WebKit -o build/desktop-ui-tests
build/desktop-ui-tests "$PWD/Resources/ui"
