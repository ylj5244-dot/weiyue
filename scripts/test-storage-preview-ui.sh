#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -parse-as-library -module-cache-path build/module-cache Sources/Store.swift Sources/ContentPreview.swift tests/ContentPreviewTests.swift -framework AppKit -framework WebKit -framework Quartz -framework PDFKit -framework Network -framework Vision -o build/content-preview-tests
xcrun swiftc -parse-as-library -module-cache-path build/module-cache Sources/Store.swift Sources/ReadingAppearance.swift tests/StoragePreviewUIHarness.swift -framework CoreText -framework AppKit -framework WebKit -o build/storage-preview-ui-tests
if [ "${1:-}" = "--compile-only" ]; then exit 0; fi
if [ "${1:-}" = "--native-only" ]; then build/content-preview-tests; exit 0; fi
if [ "${1:-}" = "--ui-only" ]; then build/storage-preview-ui-tests "$PWD/Resources/ui"; exit 0; fi
build/content-preview-tests
build/storage-preview-ui-tests "${1:-$PWD/Resources/ui}"
