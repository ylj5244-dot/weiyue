#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -parse-as-library -module-cache-path build/module-cache Sources/Store.swift tests/ProductLogicUIHarness.swift -framework AppKit -framework WebKit -o build/product-logic-ui-tests
build/product-logic-ui-tests "$PWD/Resources/ui"
