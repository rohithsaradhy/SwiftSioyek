#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/build/clang-cache"
mkdir -p build
swift test --disable-sandbox --scratch-path build/spm --cache-path build/cache --config-path build/config --security-path build/security "$@"
