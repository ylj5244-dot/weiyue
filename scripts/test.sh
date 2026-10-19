#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
node --test tests/*.test.cjs
xcrun swiftc -module-cache-path build/module-cache Sources/Store.swift tests/StoreTests.swift -o build/store-tests
build/store-tests
xcrun swiftc -module-cache-path build/module-cache Sources/Store.swift Sources/AIClient.swift tests/AITests.swift -o build/ai-tests
xcrun swiftc -module-cache-path build/module-cache Sources/Store.swift Sources/AIClient.swift tests/KeychainInteractionTests.swift -o build/keychain-policy-tests
build/keychain-policy-tests
build/ai-tests
xcrun swiftc -module-cache-path build/module-cache Sources/Store.swift Sources/MediaPolicy.swift tests/MediaTests.swift -o build/media-tests
build/media-tests
xcrun swiftc -module-cache-path build/module-cache Sources/Store.swift Sources/MediaPolicy.swift Sources/WorkspacePolicy.swift tests/WorkspaceTests.swift -o build/workspace-tests
build/workspace-tests
xcrun swiftc -module-cache-path build/module-cache Sources/Store.swift Sources/ContentExtractor.swift tests/ContentExtractorTests.swift -framework AppKit -framework Vision -framework PDFKit -o build/content-tests
build/content-tests

xcrun swiftc -module-cache-path build/module-cache Sources/Store.swift Sources/AIClient.swift tests/AIStreamingTests.swift -o build/ai-streaming-tests
build/ai-streaming-tests
xcrun swiftc -module-cache-path build/module-cache Sources/Store.swift Sources/DirectInput.swift tests/DirectInputTests.swift -framework AppKit -framework PDFKit -o build/direct-input-tests
build/direct-input-tests
xcrun swiftc -module-cache-path build/module-cache Sources/Store.swift Sources/MediaPolicy.swift Sources/WorkspacePolicy.swift Sources/CacheCleaner.swift tests/CacheCleanerTests.swift -o build/cache-cleaner-tests
build/cache-cleaner-tests
xcrun swiftc -module-cache-path build/module-cache Sources/Store.swift tests/StoreConcurrencyTests.swift -o build/store-concurrency-tests
build/store-concurrency-tests

xcrun swiftc -module-cache-path build/module-cache Sources/Store.swift Sources/AIClient.swift Sources/WebSearchClient.swift tests/WebSearchTests.swift -o build/web-search-tests
build/web-search-tests

xcrun swiftc -parse-as-library -module-cache-path build/module-cache Sources/Store.swift Sources/AttachmentPreview.swift tests/AttachmentPreviewTests.swift -framework AppKit -framework AVKit -framework AVFoundation -o build/attachment-preview-tests
build/attachment-preview-tests

xcrun swiftc -module-cache-path build/module-cache Sources/Store.swift Sources/ReadingAppearance.swift tests/ReadingAppearanceTests.swift -framework AppKit -framework CoreText -o build/reading-appearance-tests
build/reading-appearance-tests

bash scripts/test-discussion-title-native.sh
