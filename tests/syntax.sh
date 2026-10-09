#!/bin/bash
# Syntax checks run by CI and before each commit: bash, PHP, the .plg XML and the dashboard JavaScript.
# Usage: bash tests/syntax.sh      (needs bash, php, python3, node)
set -e
cd "$(dirname "$0")/.."
P=source/usr/local/emhttp/plugins/rebalance
bash -n $P/scripts/rebalance.sh
bash -n $P/scripts/rebalance-ctl
bash -n build.sh
for f in $P/include/*.php; do php -l "$f" >/dev/null; done
# the plugin manager parses the .plg as XML; a stray & breaks installs
python3 -c "import xml.etree.ElementTree as E; E.parse('rebalance.plg')"
node --check $P/include/common.js
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
for p in $P/*.page; do   # each page's inline <script>, with its PHP echo tags blanked
  sed -n '/^<script>$/,/^<\/script>$/{//!p}' "$p" | sed 's/<?=[^?]*?>//g' > "$T/page.js"
  node --check "$T/page.js" || { echo "JavaScript syntax error in $p"; exit 1; }
done
echo "syntax ok"
