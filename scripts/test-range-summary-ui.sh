#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -parse-as-library -module-cache-path build/module-cache tests/RangeSummaryUIHarness.swift -framework AppKit -framework WebKit -o build/range-summary-ui-tests
build/range-summary-ui-tests "$PWD/Resources/ui"
