#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -parse-as-library -module-cache-path build/module-cache tests/AttachmentActionsUIHarness.swift -framework AppKit -framework WebKit -o build/attachment-actions-ui-tests
if [ "${1:-}" = "--compile-only" ]; then exit 0; fi
source="${1:-$PWD/Resources/ui}"
build/attachment-actions-ui-tests "$source"
