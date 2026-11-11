#!/bin/sh
set -eu
# Xcode builds the Metal shader library; plain swift build/run does not.
eval_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_root="$eval_root/.derived-data"
(cd "$eval_root" && xcodebuild -quiet -workspace LocalModelEval.xcworkspace -scheme LocalModelEval -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$build_root" \
    CODE_SIGNING_ALLOWED=NO build)
exec "$build_root/Build/Products/Release/LocalModelEval" "$@"
