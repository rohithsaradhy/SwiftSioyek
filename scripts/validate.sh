#!/bin/zsh
# One entry point for local validation and its required Xcode service access.
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build
./scripts/test.sh > build/tests.log 2>&1
SWIFTSIOYEK_TEST_CONFIGURATION=Release ./scripts/test-ui.sh \
  CODE_SIGN_ENTITLEMENTS=Resources/Debug.entitlements ENABLE_APP_SANDBOX=NO "$@" \
  > build/ui-validation-run.log 2>&1
./scripts/build-app.sh > build/release-build-run.log 2>&1
print "Core, integration, and UI checks passed. Release app: $PWD/build/SwiftSioyek.app"
