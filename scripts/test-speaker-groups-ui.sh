#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -parse-as-library -module-cache-path build/module-cache tests/SpeakerGroupsUIHarness.swift -framework AppKit -framework WebKit -o build/speaker-groups-ui-tests
build/speaker-groups-ui-tests "$PWD/Resources/ui"
