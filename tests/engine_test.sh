#!/bin/bash
# Integration test: runs the real engine and status endpoint against a fake 4-disk array.
#   - stub df: fixed disk sizes, "used" = du of each fake disk directory
#   - covers: CRLF share configs, share exclusions, collisions, hardlink and in-progress skips,
#     plan / run, real rsync moves, pause / resume / stop, abort, status.php JSON
# Usage: bash tests/engine_test.sh      (needs bash, rsync, php, python3)
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
PLUG=$REPO/source/usr/local/emhttp/plugins/rebalance
ENGINE=$PLUG/scripts/rebalance.sh
STATUS=$PLUG/include/status.php
T=$(mktemp -d)
trap 'pkill -f "$T" 2>/dev/null; rm -rf "$T"' EXIT
FAILS=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
st() { sed -n "s/^$1=//p" "$T/run/status" 2>/dev/null; }

make_fixture() {
  rm -rf "$T/mnt" "$T/run" "$T/sizes" "$T/cfg" "$T/bin"
  mkdir -p "$T/bin" "$T/sizes" "$T/run" "$T/cfg/shares"
  cat > "$T/bin/df" <<EOF
#!/bin/bash
fields=""; paths=()
for a in "\$@"; do case \$a in -k) ;; --output=*) fields=\${a#--output=};; *) paths+=("\$a");; esac; done
IFS=, read -ra F <<< "\$fields"; echo "\${F[*]}"
for p in "\${paths[@]}"; do
  d=\${p##*/}; size=\$(cat "$T/sizes/\$d"); used=\$(du -sk "\$p" | cut -f1); avail=\$((size - used)); row=()
  for f in "\${F[@]}"; do case \$f in target) row+=("\$p");; size) row+=("\$size");; used) row+=("\$used");; avail) row+=("\$avail");; esac; done
  echo "\${row[*]}"
done
EOF
  chmod +x "$T/bin/df"
  local M=$T/mnt
  mk() { mkdir -p "$M/$1/$2"; dd if=/dev/urandom of="$M/$1/$2/data.bin" bs=4k count=$(( $3 / 4 )) status=none; }
  echo 2000 > "$T/sizes/disk1"; echo 2000 > "$T/sizes/disk2"; echo 4000 > "$T/sizes/disk3"; echo 4000 > "$T/sizes/disk4"
  mk disk1 "tv/Show A (2001)" 600; mk disk1 "tv/Show B" 500; mk disk1 "movies/Movie One (2020)" 400; mk disk1 "movies/Movie Two" 300
  mk disk2 "movies/Movie Three" 400; mk disk2 "tv/Show A (2001)" 40
  mk disk3 "tv/Show C" 700; mk disk3 "movies/Movie Four" 500; touch "$M/disk3/movies/Movie Four/ep.part"
  mk disk4 "tv/Show D" 800
  mkdir -p "$M/disk1/downloads"; ln "$M/disk1/movies/Movie Two/data.bin" "$M/disk1/downloads/seed.bin"
  if [[ ${1:-} == extra ]]; then
    for i in 5 6 7 8; do mk disk1 "movies/Small $i" 100; done
  fi
  find "$M" -exec touch -h -d '2 hours ago' {} +
  printf 'mdState="STARTED"\nmdResyncPos="0"\nmd_write_method="1"\n' > "$T/var.ini"
  printf 'shareUserInclude=""\r\nshareUserExclude=""\r\n' > "$T/cfg/share.cfg"          # Unraid writes CRLF
  printf 'shareInclude=""\r\nshareExclude="disk4"\r\n' > "$T/cfg/shares/tv.cfg"
  printf 'TOLERANCE_PCT="5"\nMIN_FREE_GB="0"\nSKIP_RECENT_MIN="15"\nNOTIFY="false"\r\n' > "$T/rb.cfg"
}

export RB_MNT=$T/mnt RB_RUN=$T/run RB_LOG=$T/rb.log RB_VAR_INI=$T/var.ini RB_SHARE_CFG=$T/cfg RB_CFG=$T/rb.cfg
export PATH=$T/bin:$PATH

echo "== plan (dry run)"
make_fixture
bash "$ENGINE" plan; rc=$?
check "plan exits 0"                         '[[ $rc == 0 ]]'
check "state is planned"                     '[[ $(st state) == planned ]]'
check "one move planned"                     '[[ $(st plan_count) == 1 ]]'
check "hardlinked items left out (2)"        '[[ $(st plan_skipped) == 2 ]]'
check "tv never planned onto disk4 (share excluded)" '! grep -P "\tdisk4\ttv/" "$T/run/plan.tsv"'
check "CRLF share config parsed (a plan exists)"     '[[ -s $T/run/plan.tsv ]]'
check "nothing moved by a dry run"           '[[ -d "$T/mnt/disk1/movies/Movie One (2020)" ]]'

echo "== run"
bash "$ENGINE" run; rc=$?
check "run exits 0"                          '[[ $rc == 0 ]]'
check "state is done"                        '[[ $(st state) == done ]]'
check "item arrived on disk4"                '[[ -f "$T/mnt/disk4/movies/Movie One (2020)/data.bin" ]]'
check "item gone from disk1"                 '[[ ! -e "$T/mnt/disk1/movies/Movie One (2020)" ]]'
check "history records the move"             'grep -q "	done	" "$T/run/history.tsv"'
check "pid file cleaned up"                  '[[ ! -f $T/run/pid ]]'
json=$(php "$STATUS")
check "status.php returns valid JSON with state done" \
  'python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d[\"state\"]==\"done\" and d[\"done\"][\"count\"]==1 and len(d[\"disks\"])==4" "$json"'

echo "== dry run on a balanced array"
make_fixture; rm -rf "$T"/mnt/disk*/*               # empty disks: nothing is over target
bash "$ENGINE" plan; rc=$?
check "balanced dry run exits 0"             '[[ $rc == 0 && $(st plan_count) == 0 ]]'
check "balanced dry run says nothing to move" '[[ $(st state) == done && $(st msg) == *"already balanced"* ]]'

echo "== dry run with an over-full disk but nothing eligible"
make_fixture
for d in "$T"/mnt/disk1/*/*/; do touch "$d/x.part"; done    # every item on the donor looks in-progress
bash "$ENGINE" plan; rc=$?
check "stuck dry run plans nothing"          '[[ $rc == 0 && $(st plan_count) == 0 && $(st plan_skipped) -ge 1 ]]'
check "stuck dry run says how many items were left out" '[[ $(st state) == done && $(st msg) == "Nothing can be moved - $(st plan_skipped) item(s) left out"* ]]'

echo "== dry run with an over-full disk but no receiving disk with room"
make_fixture
sed -i 's/MIN_FREE_GB="0"/MIN_FREE_GB="1"/' "$T/rb.cfg"      # 1 GiB free-space floor: no fake disk can receive anything
bash "$ENGINE" plan; rc=$?
check "size-limited dry run explains the limit" '[[ $rc == 0 && $(st plan_count) == 0 && $(st plan_skipped) == 0 && $(st state) == done && $(st msg) == "Nothing can be moved - no receiving disk or size limit fits"* ]]'

echo "== pause / resume / stop"
make_fixture extra
mkdir -p "$T/slow"
REAL_RSYNC=$(command -v rsync)
cat > "$T/slow/rsync" <<EOF
#!/bin/bash
# emits rsync --info=progress2 style updates, then does the real copy
for p in 10 40 70; do printf '      1,234,567  %s%%    2.50MB/s    0:00:03\\r' \$p; sleep 1; done
exec "$REAL_RSYNC" "\$@"
EOF
chmod +x "$T/slow/rsync"
PATH=$T/slow:$PATH setsid bash "$ENGINE" run & sleep 2.5
check "running with a progress feed"         '[[ $(st state) == running && -s $T/run/progress ]]'
check "status.php reports current move"      'php "$STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"current\"] and d[\"current\"][\"pct\"]>0"'
echo pause > "$T/run/control"
check "status.php reports the pending pause" 'php "$STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"state\"]==\"running\" and d[\"request\"]==\"pause\""'
sleep 5
check "paused after the current move"        '[[ $(st state) == paused && $(st done_count) == 1 ]]'
check "pause start recorded"                 '[[ $(st paused_since) =~ ^[0-9]+$ ]]'
sleep 2
check "status.php counts the ongoing pause"  'php "$STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"paused_s\"]>=2"'
echo resume > "$T/run/control"; sleep 4    # > the 3 s pause poll
check "resumed"                              '[[ $(st state) == running ]]'
check "pause time accumulated on resume"     '(( $(st paused_s) >= 2 )) && [[ -z $(st paused_since) ]]'
check "status.php: no pending request after resume" 'php "$STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"request\"]==\"\""'
echo stop > "$T/run/control"; n=$(st done_count)     # read after the request: only the move in flight may still finish
check "moves remain after the stop request"  '(( $(st plan_count) - n >= 2 ))'
for _ in $(seq 40); do [[ $(st state) == running ]] || break; sleep 0.5; done
check "stopped after the current move"       '[[ $(st state) == stopped ]] && (( $(st done_count) - n <= 1 ))'

echo "== parity check pause"
make_fixture extra
PATH=$T/slow:$PATH RB_BUSY_POLL_S=1 setsid bash "$ENGINE" run & sleep 2.5
sed -i 's/^mdResyncPos="0"/mdResyncPos="1000"/' "$T/var.ini"   # a parity check starts during the first move
sleep 5
check "parity check pauses before the next move" '[[ $(st state) == paused && $(st pause_reason) == "parity check/rebuild" && $(st paused_since) =~ ^[0-9]+$ ]]'
sed -i 's/^mdResyncPos=.*/mdResyncPos="0"/' "$T/var.ini"; sleep 3    # > the 1 s poll set by RB_BUSY_POLL_S
check "resumes when parity is idle, pause time counted" '[[ $(st state) == running && -z $(st paused_since) ]] && (( $(st paused_s) >= 2 ))'
pid=$(cat "$T/run/pid" 2>/dev/null); [[ -n $pid ]] && kill -TERM -- "-$pid" 2>/dev/null; sleep 1.5

echo "== abort"
make_fixture extra
PATH=$T/slow:$PATH setsid bash "$ENGINE" run & sleep 2
pid=$(cat "$T/run/pid" 2>/dev/null)
kill -TERM -- "-$pid" 2>/dev/null; sleep 1.5
check "state is aborted"                     '[[ $(st state) == aborted ]]'
check "engine process group is gone"         '[[ -z $(ps -eo pgid=,stat= | awk -v g="$pid" '"'"'$1==g && $2 !~ /Z/'"'"') ]]'    # zombies await reaping by init
check "pid file cleaned up"                  '[[ ! -f $T/run/pid ]]'

echo
if (( FAILS )); then echo "$FAILS check(s) failed"; echo "--- engine log:"; cat "$T/rb.log"; exit 1; fi
echo "all checks passed"
