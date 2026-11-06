#!/bin/zsh
# Runs the unit tests: Swift core (compiled with swiftc, no Xcode needed) and the JS port (node --test).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
swiftc -O -o "$OUT/swift-tests" \
    tests/swift/main.swift QuickLook/HTMLRenderer.swift Sources/Grizzly/Core/FileLoader.swift \
    Sources/Grizzly/Core/FileType.swift Sources/Grizzly/Core/Updater.swift Sources/Grizzly/Core/SyntaxEngine.swift Sources/Grizzly/Library/LibraryStore.swift Sources/Grizzly/Core/CSVTable.swift Sources/Grizzly/Core/MarkdownParser.swift Sources/Grizzly/Core/InlineMarkup.swift Sources/Grizzly/Core/RichFormat.swift Sources/Grizzly/Core/Attachments.swift Sources/Grizzly/Core/BinaryDelta.swift Sources/Grizzly/Core/AppPatch.swift Sources/Grizzly/Core/ContentsLister.swift 2>&1 | tail -20
"$OUT/swift-tests"
node --test tests/*.test.cjs
