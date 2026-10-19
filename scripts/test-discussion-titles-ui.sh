#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -parse-as-library -module-cache-path build/module-cache Sources/Store.swift tests/DiscussionTitlesUIHarness.swift -framework AppKit -framework WebKit -o build/discussion-titles-ui-tests
build/discussion-titles-ui-tests "$PWD/Resources/ui"
