#!/bin/zsh
# Copies the prebuilt iOS pieces Henge links into ios/deps (not in git):
#   StikJIT.xcframework   Built-in StikJIT (MPL-2.0), as Husk vendors it
#   libhusk_rppairing.a   on-device pairing (Husk's src/rppairing-ios, scripts/build_rppairing_ios.sh)
# (libslirp and GLib come from ios/Frameworks/Slirp.xcframework and GLib.xcframework via crate/fetch-frameworks.sh.)
set -e
HUSK=${HUSK:-$HOME/Documents/Coding/Husk}
DEPS="$(cd "$(dirname "$0")/.." && pwd)/deps"
mkdir -p "$DEPS/lib"
rm -rf "$DEPS/StikJIT.xcframework"
ditto "$HUSK/src/app/Frameworks/StikJIT.xcframework" "$DEPS/StikJIT.xcframework"
cp "$HUSK/build/ios-arm64/lib/libhusk_rppairing.a" "$DEPS/lib/"
echo "deps in $DEPS"
