#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/build/clang-cache"
mkdir -p build
swift build --disable-sandbox --scratch-path build/spm --cache-path build/cache --config-path build/config --security-path build/security -c release --product ReaderDiagnostics > build/diagnostics-build.log 2>&1 || { tail -n 20 build/diagnostics-build.log; exit 1; }
diagnostics_path="$(swift build --disable-sandbox --scratch-path build/spm --cache-path build/cache --config-path build/config --security-path build/security -c release --show-bin-path)/ReaderDiagnostics"
"$diagnostics_path" fixtures "$PWD/build/fixtures"
"$diagnostics_path" benchmark "$PWD/build/fixtures"
