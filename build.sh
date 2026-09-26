#!/bin/bash
# Builds the Array Rebalance plugin package.
# Output: releases/rebalance-<version>-x86_64-1.txz
#
# Usage:
#   bash build.sh [version]        (default: today, YYYY.MM.DD)
#
# Releases are cut by CI (.github/workflows/release.yml) when a date tag is
# pushed; run this locally only to test a build or side-load a package.
set -euo pipefail
cd "$(dirname "$0")"

NAME=rebalance
VERSION=${1:-$(date +%Y.%m.%d)}
SRC=source/usr/local/emhttp/plugins/$NAME
OUTPUT=releases/$NAME-$VERSION-x86_64-1.txz

echo "==> Array Rebalance build  (version: $VERSION)"

bash -n "$SRC/scripts/rebalance.sh"
bash -n "$SRC/scripts/rebalance-ctl"
if command -v php >/dev/null; then
  for f in "$SRC"/include/*.php; do php -l "$f" >/dev/null; done
fi

chmod 755 "$SRC"/scripts/*
mkdir -p releases
rm -f "$OUTPUT"
# makepkg is Slackware-only; a root-owned tar.xz of the usr/ tree is what upgradepkg installs.
tar --owner=0 --group=0 --sort=name -C source -cJf "$OUTPUT" usr

MD5=$(md5sum "$OUTPUT" | cut -d' ' -f1)
echo "--> $OUTPUT"
echo "--> MD5: $MD5"
