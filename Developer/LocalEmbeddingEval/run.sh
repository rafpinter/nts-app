#!/bin/sh
set -eu
# Build with Xcode so MLX's Metal shader library is available.
eval_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_root="$eval_root/.derived-data"
package_cache="${EMBEDDING_EVAL_PACKAGE_CACHE:-$build_root/SourcePackages}"
(cd "$eval_root" && xcodebuild -quiet -workspace LocalEmbeddingEval.xcworkspace \
    -scheme LocalEmbeddingEval -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$build_root" -clonedSourcePackagesDirPath "$package_cache" -skipPackageUpdates -onlyUsePackageVersionsFromResolvedFile \
    CODE_SIGNING_ALLOWED=NO build)
exec "$build_root/Build/Products/Release/LocalEmbeddingEval" "$@"
