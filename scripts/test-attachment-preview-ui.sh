#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
xcrun swiftc -parse-as-library -module-cache-path build/module-cache Sources/Store.swift Sources/AttachmentPreview.swift tests/AttachmentPreviewUIHarness.swift -framework AppKit -framework AVKit -framework AVFoundation -o build/attachment-preview-ui-tests
build/attachment-preview-ui-tests
