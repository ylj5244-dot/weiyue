#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -parse-as-library -module-cache-path build/module-cache tests/WebSearchUIHarness.swift -framework AppKit -framework WebKit -o build/web-search-ui-tests
build/web-search-ui-tests "$PWD/Resources/ui"
