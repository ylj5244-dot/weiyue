#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
# Compile the actual AppDelegate; replace only the executable entry point with
# the isolated test host so the user's accounts and official website never open.
python3 - <<'PY'
from pathlib import Path
source = Path('Sources/App.swift').read_text()
marker = '\n@main struct Main {'
assert source.count(marker) == 1
Path('build/AppDelegateLifecycleFixture.swift').write_text(source.split(marker)[0] + '\n')
PY
xcrun swiftc -parse-as-library -module-cache-path build/module-cache \
  Sources/Store.swift Sources/AIClient.swift Sources/DiscussionTitles.swift Sources/WebSearchClient.swift Sources/MediaPolicy.swift Sources/MediaStore.swift \
  Sources/WorkspacePolicy.swift Sources/ReadingAppearance.swift Sources/ContentExtractor.swift Sources/DirectInput.swift \
  Sources/CacheCleaner.swift Sources/AttachmentPreview.swift build/AppDelegateLifecycleFixture.swift tests/BackgroundLifecycleUIHarness.swift \
  -framework CoreText -framework AppKit -framework WebKit -framework Security -framework Quartz -framework Vision -framework PDFKit -framework AVKit -framework AVFoundation \
  -o build/background-lifecycle-ui-tests
build/background-lifecycle-ui-tests
