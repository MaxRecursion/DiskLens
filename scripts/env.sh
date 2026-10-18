# Shared build environment for DiskLens (sourced by the other scripts).
# Only the Xcode Command Line Tools are installed on this Mac. The macOS 27 SDK implements SwiftUI's
# @State as a compiler macro whose plugin (SwiftUIMacros) ships only with Xcode, so we build against
# the newest CLT SDK that still declares @State as a property wrapper. The app runs natively on 27.x.
CLT=/Library/Developer/CommandLineTools
if [ -z "${SDKROOT:-}" ]; then
  for v in 26.5 26; do
    if [ -d "$CLT/SDKs/MacOSX$v.sdk" ]; then export SDKROOT="$CLT/SDKs/MacOSX$v.sdk"; break; fi
  done
fi
# Xcode users can simply build with the default SDK.
if xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then unset SDKROOT; fi
TESTING_PLUGIN_DIR="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
