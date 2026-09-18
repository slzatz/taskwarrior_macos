#!/bin/sh
# Prints an SDKROOT for `swift build`, or nothing if the default SDK already works.
#
# SwiftUI's @State is a macro in the macOS 27 SDK, expanded by a SwiftUIMacros
# plugin that only Xcode's toolchain ships -- the Command Line Tools toolchain
# has no such plugin, so every @State fails to compile.  When the default SDK
# cannot expand the macro, fall back to the newest installed SDK that can.
#
# With Xcode installed the first probe succeeds and this prints nothing, which
# leaves SDKROOT unset and the build on the current SDK.

set -u

SRC="$(mktemp -t swiftui-probe).swift"
trap 'rm -f "$SRC"' EXIT INT TERM
cat > "$SRC" <<'SWIFT'
import SwiftUI
struct Probe: View {
    @State private var value = 0
    var body: some View { EmptyView() }
}
SWIFT

# No -target: whether the toolchain can expand the macro does not depend on the
# deployment target, and this way the probe can't drift from Package.swift.
probe() {
    if [ -n "${1:-}" ]; then
        xcrun swiftc -typecheck -sdk "$1" "$SRC" >/dev/null 2>&1
    else
        xcrun swiftc -typecheck "$SRC" >/dev/null 2>&1
    fi
}

# The default SDK is the one we want whenever it works.
probe "" && exit 0

DEFAULT_SDK="$(xcrun --show-sdk-path 2>/dev/null)" || exit 0
[ -n "$DEFAULT_SDK" ] || exit 0
SDK_DIR="$(dirname "$DEFAULT_SDK")"

# Newest first, by the version in the name; MacOSX.sdk is the unversioned alias
# for the default, which we have already ruled out.
seen=""
for sdk in $(ls "$SDK_DIR" 2>/dev/null | sed -n 's/^MacOSX\([0-9][0-9.]*\)\.sdk$/\1/p' | sort -Vr); do
    path="$SDK_DIR/MacOSX$sdk.sdk"
    real="$(cd "$path" 2>/dev/null && pwd -P)" || continue
    case " $seen " in *" $real "*) continue ;; esac
    seen="$seen $real"
    if probe "$path"; then
        echo "$path"
        exit 0
    fi
done

# Nothing worked; print nothing and let the build report the real error.
exit 0
