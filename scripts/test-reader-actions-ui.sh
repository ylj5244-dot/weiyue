#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -parse-as-library -module-cache-path build/module-cache Sources/Store.swift tests/ReaderActionsUIHarness.swift -framework AppKit -framework WebKit -o build/reader-actions-ui-tests
source="${1:-$PWD/Resources/ui}"
if [ "$#" -gt 0 ]; then shift; fi
build/reader-actions-ui-tests "$source" "$@"
