#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -parse-as-library -module-cache-path build/module-cache tests/GroupUnreadUIHarness.swift -framework AppKit -framework WebKit -o build/group-unread-ui-tests
build/group-unread-ui-tests "$PWD/Resources/ui"
