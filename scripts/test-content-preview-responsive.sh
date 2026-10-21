#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -parse-as-library -module-cache-path build/module-cache Sources/Store.swift Sources/ContentPreview.swift tests/ContentPreviewResponsiveTests.swift -framework AppKit -framework WebKit -framework Quartz -framework Network -o build/content-preview-responsive-tests
if [ "${1:-}" = "--compile-only" ]; then exit 0; fi
build/content-preview-responsive-tests
