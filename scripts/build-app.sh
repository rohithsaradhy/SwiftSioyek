#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/manifest-module-cache"
mkdir -p build
/usr/bin/python3 scripts/generate-project.py
xcodebuild -project SwiftSioyek.xcodeproj -scheme SwiftSioyek -configuration Release -derivedDataPath "$PWD/build/xcode" -clonedSourcePackagesDirPath "$PWD/build/packages" -packageCachePath "$PWD/build/package-cache" -destination 'platform=macOS,arch=arm64' CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build "$@" > build/xcode-release.log 2>&1 || { tail -n 70 build/xcode-release.log; exit 1; }
ditto build/xcode/Build/Products/Release/SwiftSioyek.app build/SwiftSioyek.app
codesign --verify --strict build/SwiftSioyek.app
print "Built: $PWD/build/SwiftSioyek.app"
