#!/usr/bin/env bash
# Build with the persistent mixed Theos toolchain (see ../MIXED_TOOLCHAIN.md).
# Usage: scripts/build.sh [rootless|roothide]
set -euo pipefail

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"

scheme=${1:-rootless}
case "$scheme" in
    rootless|roothide) ;;
    *) echo "usage: $0 [rootless|roothide]" >&2; exit 1 ;;
esac

: "${PACKAGE_VERSION:=$(awk '$1 == "Version:" && NF == 2 { print $2 }' control)}"

export THEOS=${THEOS:-/home/nick/roothide-theos}
export TARGET_CC=${TARGET_CC:-/home/nick/Documents/iOS/cc-mixed}
export TARGET_CXX=${TARGET_CXX:-/home/nick/Documents/iOS/cxx-mixed}
export TARGET_LD=${TARGET_LD:-/home/nick/Documents/iOS/cxx-mixed}
export THEOS_PACKAGE_SCHEME=$scheme

make clean package FINALPACKAGE=1 DEBUG=0 \
    ARCHS='arm64 arm64e' \
    ABI_SUFFIX= \
    PACKAGE_VERSION="$PACKAGE_VERSION"
