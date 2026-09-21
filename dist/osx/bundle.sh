#!/usr/bin/env bash

set -euo pipefail

LANGUAGES="bs ca cs da de el eo es fi fr gl he hr hu id it ja ko lv nb nl nn pl pt_BR ru sk sr@latin sv th tr uk vi zh_CN zh_TW"

cd $(dirname $0)/../..

rm -f src/spek

./autogen.sh && make -j8 || exit 1

cd dist/osx
rm -fr Spek.app
mkdir -p Spek.app/Contents/MacOS
mkdir -p Spek.app/Contents/Frameworks
mkdir -p Spek.app/Contents/Resources
mv ../../src/spek Spek.app/Contents/MacOS/Spek
cp Info.plist Spek.app/Contents/
cp Spek.icns Spek.app/Contents/Resources/
cp *.png Spek.app/Contents/Resources/
cp ../../CREDITS.md Spek.app/Contents/Resources/
cp ../../LICENSE Spek.app/Contents/Resources/
cp ../../README.md Spek.app/Contents/Resources/
mkdir Spek.app/Contents/Resources/lic
cp ../../lic/* Spek.app/Contents/Resources/lic/

# Homebrew's prefix differs between Intel (/usr/local) and Apple Silicon
# (/opt/homebrew); detect it instead of hardcoding one, so this script works
# on both without branching.
BREW_PREFIX=$(brew --prefix)

for lang in $LANGUAGES; do
    mkdir -p Spek.app/Contents/Resources/"$lang".lproj
    cp -v ../../po/"$lang".gmo Spek.app/Contents/Resources/"$lang".lproj/spek.mo
    cp -v "$BREW_PREFIX"/share/locale/"$lang"/LC_MESSAGES/wxstd-3.2.mo Spek.app/Contents/Resources/"$lang".lproj/ || echo "No WX translation for $lang"
done
mkdir -p Spek.app/Contents/Resources/en.lproj

BINS="Spek.app/Contents/MacOS/Spek"
while [ ! -z "$BINS" ]; do
    NEWBINS=""
    for bin in $BINS; do
        echo "Updating dependendies for $bin."
        LIBS=$(otool -L $bin | { grep "$BREW_PREFIX" || test $? = 1; } | tr -d '\t' | awk '{print $1}')
        for lib in $LIBS; do
            reallib=$(realpath $lib)
            libname=$(basename $reallib)
            install_name_tool -change $lib @executable_path/../Frameworks/$libname $bin
            if [ ! -f Spek.app/Contents/Frameworks/$libname ]; then
                echo "\tBundling $reallib."
                cp $reallib Spek.app/Contents/Frameworks/
                chmod +w Spek.app/Contents/Frameworks/$libname
                install_name_tool -id @executable_path/../Frameworks/$libname Spek.app/Contents/Frameworks/$libname
                NEWBINS="$NEWBINS Spek.app/Contents/Frameworks/$libname"
            fi
        done
    done
    BINS="$NEWBINS"
done

cd ../..

# Set SKIP_DMG=1 to stop after producing Spek.app, e.g. to lipo in an
# x86_64 slice (see build-deps-x86_64.sh) before packaging (see release.yml).
if [ "${SKIP_DMG:-0}" != "1" ]; then
    ./dist/osx/make-dmg.sh
fi
