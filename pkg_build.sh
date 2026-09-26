#!/bin/bash
# Build the plugin package and stamp version + MD5 into rebalance.plg.
#   ./pkg_build.sh              -> version = today (YYYY.MM.DD)
#   ./pkg_build.sh 2026.09.25a  -> explicit version (use a letter suffix for same-day rebuilds)
set -euo pipefail
cd "$(dirname "$0")"

NAME=rebalance
VERSION=${1:-$(date +%Y.%m.%d)}
PKG="$NAME-$VERSION-x86_64-1.txz"
SRC=source
PLG=$NAME.plg

# sanity checks
bash -n "$SRC/usr/local/emhttp/plugins/$NAME/scripts/rebalance.sh"
bash -n "$SRC/usr/local/emhttp/plugins/$NAME/scripts/rebalance-ctl"
if command -v php >/dev/null; then
  for f in "$SRC"/usr/local/emhttp/plugins/$NAME/include/*.php; do php -l "$f" >/dev/null; done
fi

chmod 755 "$SRC"/usr/local/emhttp/plugins/$NAME/scripts/*
mkdir -p archive
rm -f "archive/$NAME-$VERSION-"*.txz

# Slackware-style package: root-relative paths, root ownership
tar --owner=0 --group=0 --sort=name -C "$SRC" -cJf "archive/$PKG" usr

MD5=$(md5sum "archive/$PKG" | cut -d' ' -f1)
sed -i -E "s|(<!ENTITY version +\")[^\"]*|\1$VERSION|; s|(<!ENTITY md5 +\")[^\"]*|\1$MD5|" "$PLG"

echo "Built archive/$PKG"
echo "MD5  $MD5"
echo "Stamped $PLG -> version $VERSION"
echo "Remember to add a ###$VERSION entry under <CHANGES> in $PLG"
