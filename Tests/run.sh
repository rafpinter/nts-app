#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
developer_dir=$(xcode-select -p)
platform_dir="$developer_dir/Platforms/MacOSX.platform/Developer"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/nts-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc \
    -module-cache-path "$test_dir/module-cache" \
    -I "$platform_dir/usr/lib" -L "$platform_dir/usr/lib" \
    -F "$platform_dir/Library/Frameworks" \
    -framework Accelerate \
    -framework SwiftUI \
    -Xlinker -rpath -Xlinker "$platform_dir/Library/Frameworks" \
    -Xlinker -rpath -Xlinker "$platform_dir/usr/lib" \
    "$project_root/Nts/FilenameModelConfiguration.swift" \
    "$project_root/Nts/FilenameSuggestions.swift" \
    "$project_root/Nts/FilenameSuggestionController.swift" \
    "$project_root/Nts/NoteIndex.swift" \
    "$project_root/Nts/SQLiteDatabase.swift" \
    "$project_root/Nts/EmbeddingRepository.swift" \
    "$project_root/Nts/NoteProjection.swift" \
    "$project_root/Nts/NoteMap.swift" \
    "$project_root/Nts/DatabaseStatus.swift" \
    "$project_root/Nts/EmbeddingModelConfiguration.swift" \
    "$project_root/Nts/LocalMLXResourceGate.swift" \
    "$project_root/Nts/NoteEmbeddingBackend.swift" \
    "$project_root/Nts/NoteEmbeddingController.swift" \
    "$project_root/Nts/NoteFileService.swift" \
    "$project_root/Nts/NoteStore.swift" \
    "$project_root/Nts/NoteNavigation.swift" \
    "$project_root/Nts/AppearanceConfiguration.swift" \
    "$project_root/Nts/DesignSystem.swift" \
    "$project_root/Nts/EditorConfiguration.swift" \
    "$project_root/Nts/ImageAssetService.swift" \
    "$project_root/Nts/MarkdownEditor.swift" \
    "$project_root/Nts/LiveMarkdown.swift" \
    "$project_root/Tests/NoteNavigationTests.swift" \
    "$project_root/Tests/NativeEditorTests.swift" \
    "$project_root/Tests/AutosaveTests.swift" \
    "$project_root/Tests/ImageAssetTests.swift" \
    "$project_root/Tests/ImageInsertionTests.swift" \
    "$project_root/Tests/LiveMarkdownTests.swift" \
    "$project_root/Tests/FilenameSuggestionTests.swift" \
    "$project_root/Tests/NoteIndexTests.swift" \
    "$project_root/Tests/EmbeddingRepositoryTests.swift" \
    "$project_root/Tests/NoteProjectionTests.swift" \
    "$project_root/Tests/NoteMapTests.swift" \
    "$project_root/Tests/LocalMLXResourceGateTests.swift" \
    "$project_root/Tests/NoteEmbeddingControllerTests.swift" \
    "$project_root/Tests/SQLiteDatabaseTests.swift" \
    "$project_root/Tests/WikiRenameTests.swift" \
    "$project_root/Tests/main.swift" \
    -o "$test_dir/NtsTests"
"$test_dir/NtsTests"
