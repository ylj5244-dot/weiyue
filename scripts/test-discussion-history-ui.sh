#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -parse-as-library -module-cache-path build/module-cache tests/DiscussionHistoryUIHarness.swift -framework AppKit -framework WebKit -o build/discussion-history-ui-tests
build/discussion-history-ui-tests "$PWD/Resources/ui"
