#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -parse-as-library -module-cache-path build/module-cache tests/CompactAIUIHarness.swift -framework AppKit -framework WebKit -o build/compact-ai-ui-tests
build/compact-ai-ui-tests "${1:-$PWD/Resources/ui}" "${2:-}"
