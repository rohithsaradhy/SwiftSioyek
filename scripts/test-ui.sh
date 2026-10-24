#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/manifest-module-cache"
mkdir -p build
if ! mkdir build/ui-test.lock 2>/dev/null; then print -u2 "Another UI test run is active. Wait for it to finish."; exit 2; fi
trap 'rmdir build/ui-test.lock 2>/dev/null || true' EXIT
/usr/bin/python3 scripts/generate-project.py
xcodebuild -project SwiftSioyek.xcodeproj -scheme SwiftSioyek -configuration "${SWIFTSIOYEK_TEST_CONFIGURATION:-Debug}" -derivedDataPath "$PWD/build/xcode" -clonedSourcePackagesDirPath "$PWD/build/packages" -packageCachePath "$PWD/build/package-cache" -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO test "$@" > build/xcode-ui-tests.log 2>&1 && test_result=0 || test_result=$?
artifact_root="$HOME/Library/Containers/app.swiftsioyek.uitests.xctrunner/Data/tmp/SwiftSioyek-validation"
if [[ -d "$artifact_root" ]]; then
  mkdir -p build/validation
  ditto "$artifact_root" build/validation
fi
if [[ $test_result -ne 0 ]]; then tail -n 80 build/xcode-ui-tests.log; exit $test_result; fi
tail -n 20 build/xcode-ui-tests.log
