#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -parse-as-library -module-cache-path build/module-cache Sources/Store.swift Sources/ReadingAppearance.swift tests/ReadingRefinementUIHarness.swift -framework CoreText -framework AppKit -framework WebKit -o build/reading-refinement-ui-tests
if [ "${1:-}" = "--compile-only" ]; then exit 0; fi
build/reading-refinement-ui-tests "$PWD/Resources/ui" "$@"
