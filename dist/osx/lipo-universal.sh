#!/usr/bin/env bash

set -euo pipefail

# Merges two single-arch Spek.app bundles (as produced by
# `SKIP_DMG=1 bundle.sh`, one per arch) into one universal (x86_64 + arm64)
# app bundle, by lipo-combining every Mach-O file and copying everything
# else (resources, translations) as-is, since those are arch-independent.
#
# Usage: lipo-universal.sh <x86_64 Spek.app> <arm64 Spek.app> <output Spek.app>

if [ $# -ne 3 ]; then
    echo "Usage: $0 <x86_64 Spek.app> <arm64 Spek.app> <output Spek.app>" >&2
    exit 1
fi

APP_X86=$1
APP_ARM=$2
OUT=$3

x86_frameworks=$(cd "$APP_X86/Contents/Frameworks" && ls | sort)
arm_frameworks=$(cd "$APP_ARM/Contents/Frameworks" && ls | sort)
if [ "$x86_frameworks" != "$arm_frameworks" ]; then
    echo "warning: bundled libraries differ between architectures, universal binary may be incomplete:" >&2
    diff <(echo "$x86_frameworks") <(echo "$arm_frameworks") >&2 || true
fi

rm -fr "$OUT"
cp -R "$APP_X86" "$OUT"

find "$APP_X86" -type f | while read -r f; do
    rel=${f#"$APP_X86"/}
    other="$APP_ARM/$rel"
    if [ -f "$other" ] && file "$f" | grep -q "Mach-O"; then
        echo "lipo: $rel"
        lipo -create "$f" "$other" -output "$OUT/$rel"
    fi
done

echo "Verifying universal binary..."
lipo -info "$OUT/Contents/MacOS/Spek"
