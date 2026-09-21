#!/usr/bin/env bash

set -euo pipefail

# Packages an existing Spek.app (built by bundle.sh) into Spek.dmg. Split out
# of bundle.sh so CI can build per-arch .app bundles, lipo them into a
# universal one (see lipo-universal.sh), and only then package the dmg.

cd "$(dirname "$0")"

VOLUME_NAME=Spek
DMG_APP=Spek.app
DMG_FILE=$VOLUME_NAME.dmg
MOUNT_POINT=$VOLUME_NAME.mounted

rm -f $DMG_FILE
rm -f $DMG_FILE.master

# Compute an approximated image size in MB, and bloat by 1MB
image_size=$(du -ck $DMG_APP | tail -n1 | cut -f1)
image_size=$((($image_size + 5000) / 1000))

echo "Creating disk image (${image_size}MB)..."
hdiutil create $DMG_FILE -megabytes $image_size -volname $VOLUME_NAME -fs HFS+ -quiet || exit $?

echo "Attaching to disk image..."
hdiutil attach $DMG_FILE -readwrite -noautoopen -mountpoint $MOUNT_POINT -quiet

echo "Populating image..."
cp -Rp $DMG_APP $MOUNT_POINT
cd $MOUNT_POINT
ln -s /Applications " "
cd ..
cp DS_Store $MOUNT_POINT/.DS_Store

echo "Detaching from disk image..."
hdiutil detach $MOUNT_POINT -quiet
mv $DMG_FILE $DMG_FILE.master

echo "Creating distributable image..."
hdiutil convert -quiet -format UDBZ -o $DMG_FILE $DMG_FILE.master
rm $DMG_FILE.master

echo "Done."
