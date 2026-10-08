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
SCRIPT=$PLUG/include/script.php
BROWSE=$PLUG/include/browse.php
ACTION=$PLUG/include/action.php
T=$(mktemp -d)
trap 'pkill -f "$T" 2>/dev/null; rm -rf "$T"' EXIT
FAILS=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
st() { sed -n "s/^$1=//p" "$T/run/status" 2>/dev/null; }
started() { for _ in $(seq 40); do [[ -n $(st state) ]] && return; sleep 0.25; done; }   # status is written after the engine clears the control file
sel() { printf '%s\n' "$@" > "$T/run/selection.tsv"; }   # Data Move: one selection.tsv line per argument

make_fixture() {
  rm -rf "$T/mnt" "$T/run" "$T/sizes" "$T/cfg" "$T/bin" "$T/notify.log"
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
  printf '#!/bin/bash\necho "$*" >> "%s/notify.log"\n' "$T" > "$T/bin/notify"; chmod +x "$T/bin/notify"   # records each notify call: ... -i <level>
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

export RB_MNT=$T/mnt RB_RUN=$T/run RB_LOG=$T/rb.log RB_VAR_INI=$T/var.ini RB_SHARE_CFG=$T/cfg RB_CFG=$T/rb.cfg RB_NOTIFY_BIN=$T/bin/notify
export PATH=$T/bin:$PATH

echo "== rsync keeps the source of a file it skips as already existing"
mkdir -p "$T/rs/src/a" "$T/rs/dst/a"
echo source > "$T/rs/src/a/f"; echo dest > "$T/rs/dst/a/f"; echo new > "$T/rs/src/a/g"
rsync -aHAX --remove-source-files --relative --ignore-existing "$T/rs/src/./a" "$T/rs/dst/" >/dev/null 2>&1; rrc=$?
check "rsync --ignore-existing keeps a skipped source file and the existing destination file" '[[ $rrc == 0 && $(cat "$T/rs/src/a/f" 2>/dev/null) == source && $(cat "$T/rs/dst/a/f") == dest ]]'
check "rsync --remove-source-files still moves the files it copied" '[[ ! -e $T/rs/src/a/g && $(cat "$T/rs/dst/a/g" 2>/dev/null) == new ]]'
rm -rf "$T/rs"

echo "== plan (dry run)"
make_fixture
mkdir -p "$T/mnt/disk1/movies/Empty Folder" && touch -h -d '2 hours ago' "$T/mnt/disk1/movies/Empty Folder"   # #7: an empty folder at item depth on the over-full disk, aged like the rest of the fixture
bash "$ENGINE" plan; rc=$?
check "plan exits 0"                         '[[ $rc == 0 ]]'
check "state is planned"                     '[[ $(st state) == planned ]]'
check "one move planned"                     '[[ $(st plan_count) == 1 ]]'
check "hardlinked items left out (2)"        '[[ $(st plan_skipped) == 2 ]]'
check "empty folder is never planned"        '! grep -q "Empty Folder" "$T/run/plan.tsv"'
check "tv never planned onto disk4 (share excluded)" '! grep -P "\tdisk4\ttv/" "$T/run/plan.tsv"'
check "CRLF share config parsed (a plan exists)"     '[[ -s $T/run/plan.tsv ]]'
check "nothing moved by a dry run"           '[[ -d "$T/mnt/disk1/movies/Movie One (2020)" ]]'
cp "$T/run/moves.sh" "$T/dry-moves.sh" 2>/dev/null
guard=$(PATH=/nonexistent /bin/bash "$T/run/moves.sh" 2>&1); grc=$?   # no rsync on PATH: a missing guard still moves nothing
check "dry run writes a move script"         '[[ -s $T/run/moves.sh ]]'
check "move script stops at its review-only guard" '[[ $grc == 1 && $guard == "Review only - start the rebalance from the dashboard" ]]'
check "move script has one rsync line per planned move" '[[ $(grep -c "^rsync " "$T/run/moves.sh" 2>/dev/null) == "$(st plan_count)" ]]'
check "script.php serves the move script"    '[[ -s $T/run/moves.sh && $(php "$SCRIPT" 2>/dev/null) == "$(cat "$T/run/moves.sh")" ]]'

echo "== run"
REAL_RSYNC=$(command -v rsync)
mkdir -p "$T/argv"; rm -f "$T/rsync.argv"
cat > "$T/argv/rsync" <<EOF
#!/bin/bash
# records the argv the engine ran rsync with, one per line, then does the real copy
printf '%s\n' "\${0##*/}" "\$@" >> "$T/rsync.argv"
exec "$REAL_RSYNC" "\$@"
EOF
chmod +x "$T/argv/rsync"
PATH=$T/argv:$PATH bash "$ENGINE" run; rc=$?
check "run exits 0"                          '[[ $rc == 0 ]]'
check "state is done"                        '[[ $(st state) == done ]]'
check "item arrived on disk4"                '[[ -f "$T/mnt/disk4/movies/Movie One (2020)/data.bin" ]]'
check "item gone from disk1"                 '[[ ! -e "$T/mnt/disk1/movies/Movie One (2020)" ]]'
check "run executes the pinned rsync command" '[[ $(cat "$T/rsync.argv" 2>/dev/null) == "$(printf "%s\n" rsync -aHAX --remove-source-files --relative --ignore-existing --info=progress2 --no-inc-recursive "$T/mnt/disk1/./movies/Movie One (2020)" "$T/mnt/disk4/")" ]]'
check "empty folder stays on disk1 after the run" '[[ -d "$T/mnt/disk1/movies/Empty Folder" ]]'
while IFS= read -r l; do a=(); eval "a=($l)" 2>/dev/null; printf '%s\n' "${a[@]}"; done < <(grep '^rsync ' "$T/dry-moves.sh" 2>/dev/null) > "$T/script.argv"
check "move script commands are the commands the run executed" '[[ -s $T/script.argv ]] && cmp -s "$T/script.argv" "$T/rsync.argv"'
check "history records the move"             'grep -q "	done	" "$T/run/history.tsv"'
check "pid file cleaned up"                  '[[ ! -f $T/run/pid ]]'
json=$(php "$STATUS")
check "status.php returns valid JSON with state done" \
  'python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d[\"state\"]==\"done\" and d[\"done\"][\"count\"]==1 and len(d[\"disks\"])==4" "$json"'

echo "== a file that appears on the destination during a move is never overwritten"
make_fixture
mkdir -p "$T/clash"
cat > "$T/clash/rsync" <<EOF
#!/bin/bash
# a file appears at the destination path between the engine's live checks and the copy
mkdir -p "$T/mnt/disk4/movies/Movie One (2020)" && echo clash > "$T/mnt/disk4/movies/Movie One (2020)/data.bin"
exec "$REAL_RSYNC" "\$@"
EOF
chmod +x "$T/clash/rsync"
PATH=$T/clash:$PATH bash "$ENGINE" run; rc=$?
check "a clash found mid-move stops the run with an error" '[[ $rc == 1 && $(st state) == error ]]'
check "the clashing destination file is kept" '[[ $(cat "$T/mnt/disk4/movies/Movie One (2020)/data.bin" 2>/dev/null) == clash ]]'
check "the source copy is kept" '[[ $(stat -c %s "$T/mnt/disk1/movies/Movie One (2020)/data.bin" 2>/dev/null) == 409600 ]]'

echo "== dry run on a balanced array"
make_fixture; rm -rf "$T"/mnt/disk*/*               # empty disks: nothing is over target
bash "$ENGINE" plan; rc=$?
check "balanced dry run exits 0"             '[[ $rc == 0 && $(st plan_count) == 0 ]]'
check "balanced dry run says nothing to move" '[[ $(st state) == done && $(st msg) == *"already balanced"* ]]'
check "balanced result is not a warning"     'php "$STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"warn\"] is False"'

echo "== dry run with an over-full disk but nothing eligible"
make_fixture
sed -i 's/NOTIFY="false"/NOTIFY="true"/' "$T/rb.cfg"
for d in "$T"/mnt/disk1/*/*/; do touch "$d/x.part"; done    # every item on the donor looks in-progress
bash "$ENGINE" plan; rc=$?
check "stuck dry run plans nothing"          '[[ $rc == 0 && $(st plan_count) == 0 && $(st plan_skipped) -ge 1 ]]'
check "stuck dry run says how many items were left out" '[[ $(st state) == done && $(st msg) == "Nothing can be moved - $(st plan_skipped) item(s) left out"* ]]'
check "stuck dry run sends a warning notification" 'grep -q -- "-i warning" "$T/notify.log"'
check "status.php flags the stuck result as a warning" 'php "$STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"warn\"] is True"'

echo "== dry run with an over-full disk but no receiving disk with room"
make_fixture
sed -i 's/MIN_FREE_GB="0"/MIN_FREE_GB="1"/' "$T/rb.cfg"      # 1 GiB free-space floor: no fake disk can receive anything
bash "$ENGINE" plan; rc=$?
check "size-limited dry run explains the limit" '[[ $rc == 0 && $(st plan_count) == 0 && $(st plan_skipped) == 0 && $(st state) == done && $(st msg) == "Nothing can be moved - no receiving disk or size limit fits"* ]]'

echo "== dry run with an over-full disk whose items are all in excluded shares"
make_fixture
echo 'EXCLUDE_SHARES="tv,movies,downloads"' >> "$T/rb.cfg"
bash "$ENGINE" plan; rc=$?
check "excluded-only dry run blames share exclusion" '[[ $rc == 0 && $(st plan_count) == 0 && $(st msg) == "Nothing can be moved - the over-full disk has no items in included shares" ]]'

echo "== dry run with an over-full disk holding only empty folders and items that do not fit"
make_fixture
rm -rf "$T/mnt/disk1/movies" "$T/mnt/disk1/downloads"; mkdir -p "$T/mnt/disk1/tv/Empty Show (2019)"   # tv may not go to disk4, and both shows are too big for disk2 and disk3
bash "$ENGINE" plan; rc=$?
check "empty folders do not hide the nothing-can-be-moved warning" '[[ $rc == 0 && $(st plan_count) == 0 && $(st state) == done && $(st warn) == 1 && $(st msg) == "Nothing can be moved - no receiving disk or size limit fits"* ]]'

echo "== a non-ASCII item name in the move script"
make_fixture
printf -v NAME 'Caf\xc3\xa9 (2019)'   # readable accented name, built from raw UTF-8 bytes
rm -rf "$T/mnt/disk1/movies/Movie One (2020)"
mkdir -p "$T/mnt/disk1/movies/$NAME"
dd if=/dev/urandom of="$T/mnt/disk1/movies/$NAME/data.bin" bs=4k count=100 status=none   # same 400 KiB as the item it replaces
find "$T/mnt/disk1/movies/$NAME" -exec touch -h -d '2 hours ago' {} +
bash "$ENGINE" plan; rc=$?
ACC=$'\xc3\xa9'   # the raw UTF-8 bytes for e-acute
check "readable non-ASCII names appear in the move script" '[[ $rc == 0 ]] && grep "^rsync " "$T/run/moves.sh" 2>/dev/null | grep -qF "$ACC"'
mkdir -p "$T/noloc"   # a box whose locale -a lists no UTF-8 locale (Golem has no C.UTF-8): the engine must not set one
printf '#!/bin/bash\nprintf "C\\nPOSIX\\n"\n' > "$T/noloc/locale"; chmod +x "$T/noloc/locale"
PATH=$T/noloc:$PATH bash "$ENGINE" plan; rc=$?
ESC='\303\251'   # e-acute as printf %q escapes it without a UTF-8 locale
check "without a listed UTF-8 locale, names stay escaped" '[[ $rc == 0 ]] && grep "^rsync " "$T/run/moves.sh" 2>/dev/null | grep -qF "$ESC"'
sed 's/^TOLERANCE_PCT=.*/TOLERANCE_PCT="99"/' "$T/rb.cfg" > "$T/bal.cfg"   # every disk within tolerance: nothing to plan
RB_CFG=$T/bal.cfg bash "$ENGINE" plan; rc=$?
check "a new run clears the previous move script" '[[ $rc == 0 && $(st plan_count) == 0 && ! -e $T/run/moves.sh ]]'

echo "== a newline or tab in a parent folder at item depth 2"
for sep in $'\n' $'\t'; do   # the item that would be planned now sits under a name that splits plan.tsv
  make_fixture
  mv "$T/mnt/disk1/movies/Movie One (2020)" "$T/mnt/disk1/movies/Movie${sep}One"
  echo 'ITEM_DEPTH="2"' >> "$T/rb.cfg"
  bash "$ENGINE" plan; rc=$?
  what=$([[ $sep == $'\n' ]] && echo newline || echo tab)
  check "a parent folder name with a $what is never planned" '[[ $rc == 0 && $(st plan_count) == 0 ]] && ! awk -F"\t" "NF != 5 { bad=1 } END { exit !bad }" "$T/run/plan.tsv"'
done

echo "== data move: a bad selection is refused"
make_fixture
ln -s "$T/mnt/disk2/movies" "$T/mnt/disk1/escape"
while IFS='|' read -r line want; do
  sel "${line//\\t/$'\t'}" $'dest\tdisk3'
  bash "$ENGINE" move-plan; rc=$?
  check "selection refused ($want): ${line//\\t/ }" '[[ $rc == 1 && $(st state) == error && $(st msg) == "Bad selection"*"$want"* ]]'
done <<'EOF'
item\tdisk9\tmovies|is not an included array disk
item\tdisk1\tmovies/../tv|is not a plain relative path
item\tdisk1\t/movies|is not a plain relative path
item\tdisk1\tmovies/Nope|does not exist
item\tdisk1\tescape|is outside disk1
bogus\tdisk1\tmovies|unknown line
EOF
sel $'item\tdisk1\tmovies' $'item\tdisk1\tmovies/Movie One (2020)' $'dest\tdisk3'
bash "$ENGINE" move-plan; rc=$?
check "selection refused: an item inside another item" '[[ $rc == 1 && $(st msg) == "Bad selection: disk1/movies/Movie One (2020) is inside disk1/movies" ]]'
sel $'item\tdisk1\tmovies/Movie One (2020)' $'bogus\tdisk2\tmovies/Movie Three' $'dest\tdisk3'   # a real run: one good item, one bad line
bash "$ENGINE" move-run; rc=$?
check "a refused selection moves nothing" '[[ $rc == 1 && -d "$T/mnt/disk1/movies/Movie One (2020)" && ! -e "$T/mnt/disk3/movies/Movie One (2020)" ]]'

echo "== data move: a folder"
make_fixture
sel $'item\tdisk1\tmovies/Movie One (2020)' $'dest\tdisk3'
bash "$ENGINE" move-run; rc=$?
check "move-run of a folder ends done in mode move-run" '[[ $rc == 0 && $(st state) == done && $(st mode) == move-run ]]'
check "the folder lands at the same path on the destination" '[[ -f "$T/mnt/disk3/movies/Movie One (2020)/data.bin" ]]'
check "the folder is gone from the source" '[[ ! -e "$T/mnt/disk1/movies/Movie One (2020)" ]]'
check "the log names the run a data move" 'grep -q "Data Move - mode: move-run" "$T/rb.log"'

echo "== data move: a single file"
make_fixture
sel $'item\tdisk1\tmovies/Movie One (2020)/data.bin' $'dest\tdisk3'
bash "$ENGINE" move-run; rc=$?
check "a single file moves to the same path" '[[ $rc == 0 && $(st state) == done && -f "$T/mnt/disk3/movies/Movie One (2020)/data.bin" && ! -e "$T/mnt/disk1/movies/Movie One (2020)/data.bin" ]]'

echo "== data move: a whole share spreads over two destinations"
make_fixture
rm -rf "$T/mnt/disk2/tv"; echo 3000 > "$T/sizes/disk3"   # disk3 has more room for the first item only
sel $'item\tdisk1\ttv' $'dest\tdisk2' $'dest\tdisk3'
bash "$ENGINE" move-plan; rc=$?
want=$(printf 'disk1\tdisk3\ttv/Show A (2001)\ndisk1\tdisk2\ttv/Show B')
check "a whole share expands to its items, largest first to the most room" '[[ $rc == 0 && $(st state) == planned && $(cut -f3- "$T/run/plan.tsv") == "$want" ]]'
check "a move dry run moves nothing" '[[ -d "$T/mnt/disk1/tv/Show A (2001)" && ! -e "$T/mnt/disk3/tv/Show A (2001)" ]]'

echo "== data move: never back to its own disk"
make_fixture
sel $'item\tdisk3\ttv/Show C' $'dest\tdisk2' $'dest\tdisk3'
bash "$ENGINE" move-plan; rc=$?
check "an item never goes back to its own disk" '[[ $rc == 0 && $(cut -f3,4 "$T/run/plan.tsv") == "$(printf "disk3\tdisk2")" ]]'

echo "== data move: a disk ticked in full never receives"
make_fixture
echo 2500 > "$T/sizes/disk3"   # disk2 would have more room than disk3
sel $'item\tdisk2\t' $'item\tdisk1\ttv/Show B' $'dest\tdisk2' $'dest\tdisk3'
bash "$ENGINE" move-plan; rc=$?
check "a disk ticked in full never receives" '[[ $rc == 0 && $(st state) == planned && $(st plan_count) == 3 ]] && ! awk -F"\t" "\$4 == \"disk2\" { f=1 } END { exit !f }" "$T/run/plan.tsv"'

echo "== data move: an item that does not fit fails the plan"
make_fixture
echo 1000 > "$T/sizes/disk2"   # room for Movie One (404) but not Show A (604)
sel $'item\tdisk1\ttv/Show A (2001)' $'item\tdisk1\tmovies/Movie One (2020)' $'dest\tdisk2'
bash "$ENGINE" move-run; rc=$?
check "an item that does not fit fails the plan with an error" '[[ $rc == 1 && $(st state) == error && $(st msg) == "1 item(s) cannot be moved"* ]]'
check "the log lists the item that does not fit" 'grep -q "PLAN-NOFIT.*tv/Show A (2001)" "$T/rb.log"'
check "nothing moves when any item does not fit" '[[ -d "$T/mnt/disk1/movies/Movie One (2020)" && ! -e "$T/mnt/disk2/movies/Movie One (2020)" ]]'
check "a failed plan still writes the move script" '[[ -s $T/run/moves.sh ]]'

echo "== data move: merge into a folder already on the destination"
make_fixture
mv "$T/mnt/disk2/tv/Show A (2001)/data.bin" "$T/mnt/disk2/tv/Show A (2001)/e02.bin"
sel $'item\tdisk1\ttv/Show A (2001)' $'dest\tdisk2' $'dest\tdisk3'
bash "$ENGINE" move-run; rc=$?
check "a destination already holding the item folder is preferred over a roomier one" '[[ $(cut -f4 "$T/run/plan.tsv") == disk2 ]]'
check "the item merges into the existing folder" '[[ $rc == 0 && $(st state) == done && -f "$T/mnt/disk2/tv/Show A (2001)/data.bin" && -f "$T/mnt/disk2/tv/Show A (2001)/e02.bin" && ! -e "$T/mnt/disk1/tv/Show A (2001)" ]]'

echo "== data move: a same-named file on the destination"
make_fixture
sel $'item\tdisk1\ttv/Show A (2001)' $'dest\tdisk2'
bash "$ENGINE" move-run; rc=$?
check "a same-named file on the destination fails the plan" '[[ $rc == 1 && $(st state) == error ]] && grep -q "PLAN-CONFLICT.*already exists at the same path on disk2" "$T/rb.log"'
check "a conflict moves nothing and keeps both copies" '[[ $(stat -c %s "$T/mnt/disk1/tv/Show A (2001)/data.bin") == 614400 && $(stat -c %s "$T/mnt/disk2/tv/Show A (2001)/data.bin") == 40960 ]]'

echo "== data move: a file on the destination where the source has a folder"
make_fixture
touch "$T/mnt/disk3/movies/Movie One (2020)"   # a file where the source has a folder
sel $'item\tdisk1\tmovies/Movie One (2020)' $'dest\tdisk3'
bash "$ENGINE" move-plan; rc=$?
check "a file where the source has a folder is a conflict" '[[ $rc == 1 && $(st state) == error ]] && grep -q "PLAN-CONFLICT" "$T/rb.log"'

echo "== data move: two ticked folders bring the same file to one disk"
make_fixture
sel $'item\tdisk1\ttv/Show A (2001)' $'item\tdisk2\ttv/Show A (2001)' $'dest\tdisk3'
bash "$ENGINE" move-plan; rc=$?
check "two ticked folders that would bring the same file to one disk fail the plan" '[[ $rc == 1 && $(st state) == error ]] && grep -q "PLAN-CONFLICT.*also sends a file with the same path" "$T/rb.log"'

echo "== data move: gather a folder split across two disks"
make_fixture
mv "$T/mnt/disk2/tv/Show A (2001)/data.bin" "$T/mnt/disk2/tv/Show A (2001)/e02.bin"
touch -h -d '2 hours ago' "$T/mnt/disk2/tv/Show A (2001)"   # the rename touched the folder; age it like the fixture
sel $'item\tdisk1\ttv/Show A (2001)' $'item\tdisk2\ttv/Show A (2001)' $'dest\tdisk3'
bash "$ENGINE" move-run; rc=$?
check "a folder split across two disks gathers on one" '[[ $rc == 0 && $(st state) == done && $(st done_count) == 2 && -f "$T/mnt/disk3/tv/Show A (2001)/data.bin" && -f "$T/mnt/disk3/tv/Show A (2001)/e02.bin" && ! -e "$T/mnt/disk1/tv/Show A (2001)" && ! -e "$T/mnt/disk2/tv/Show A (2001)" ]]'

echo "== data move: a conflict that appears after planning"
make_fixture
mkdir -p "$T/late"
cat > "$T/late/rsync" <<EOF
#!/bin/bash
# while the first move copies, a file appears where the second item is headed
mkdir -p "$T/mnt/disk3/movies/Movie One (2020)" && echo late > "$T/mnt/disk3/movies/Movie One (2020)/data.bin"
exec "$REAL_RSYNC" "\$@"
EOF
chmod +x "$T/late/rsync"
sel $'item\tdisk1\ttv/Show A (2001)' $'item\tdisk1\tmovies/Movie One (2020)' $'dest\tdisk3'
PATH=$T/late:$PATH bash "$ENGINE" move-run; rc=$?
check "a conflict that appears after planning is skipped live" '[[ $rc == 0 && $(st state) == done && $(st done_count) == 1 && $(st skipped) == 1 ]] && grep -q "SKIP.*Movie One (2020).*a file already exists" "$T/rb.log"'
check "a live-skipped item keeps both copies" '[[ $(cat "$T/mnt/disk3/movies/Movie One (2020)/data.bin") == late && -s "$T/mnt/disk1/movies/Movie One (2020)/data.bin" ]]'

echo "== browse.php"
make_fixture
printf 'EXCLUDE_SHARES="downloads"\nEXCLUDE_DISKS="disk4"\n' >> "$T/rb.cfg"
ln -s "$T/mnt/disk2/movies" "$T/mnt/disk1/movies/Elsewhere"; mkdir -p "$T/mnt/disk1/movies/.hidden" "$T/mnt/cache/movies"
browse() { php -r '$_GET = ["disk" => $argv[1], "path" => $argv[2]]; include $argv[3];' -- "$1" "$2" "$BROWSE"; }
for bad in 'disk1|movies/..' 'disk1|/movies' 'cache|movies' 'disk4|tv' 'disk1|movies/Elsewhere' 'disk1|movies/Nope'; do
  check "browse.php refuses ${bad/|/ }" 'browse "${bad%%|*}" "${bad#*|}" | python3 -c "import json,sys; assert json.load(sys.stdin)[\"ok\"] is False"'
done
check "browse.php lists a folder with sizes" 'browse disk1 movies | python3 -c "import json,sys; e={x[\"name\"]: x for x in json.load(sys.stdin)[\"entries\"]}; m=e[\"Movie One (2020)\"]; assert m[\"type\"]==\"dir\" and m[\"kib\"]>=400 and not m[\"excluded\"] and e[\"Elsewhere\"][\"type\"]==\"file\" and \".hidden\" not in e, e"'
check "browse.php lists a file with its size" 'browse disk1 "movies/Movie One (2020)" | python3 -c "import json,sys; e=json.load(sys.stdin)[\"entries\"]; assert e==[{\"name\":\"data.bin\",\"type\":\"file\",\"kib\":400,\"excluded\":False}], e"'
check "browse.php marks shares excluded in settings" 'browse disk1 "" | python3 -c "import json,sys; e={x[\"name\"]: x[\"excluded\"] for x in json.load(sys.stdin)[\"entries\"]}; assert e[\"downloads\"] and not e[\"tv\"] and not e[\"movies\"], e"'
rm -rf "$T/mnt/cache"

echo "== pause / resume / stop"
make_fixture extra
mkdir -p "$T/slow"
REAL_RSYNC=$(command -v rsync)
cat > "$T/slow/rsync" <<EOF
#!/bin/bash
# emits rsync --info=progress2 style updates, then does the real copy
printf '%s\n' "\${0##*/}" "\$@" > "$T/slow.argv"
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

echo "== stop sent just as a pause is resumed"
make_fixture extra
ctl() { echo "$1" > "$T/run/control.tmp" && mv -f "$T/run/control.tmp" "$T/run/control"; }   # atomic, like rebalance-ctl
REAL_CAT=$(command -v cat)
mkdir -p "$T/race"
cat > "$T/race/cat" <<EOF
#!/bin/bash
# the engine reads the control file with cat; the first time it reads "resume", a stop lands straight after the read
"$REAL_CAT" "\$@"; rc=\$?
if [[ \$1 == "$T/run/control" && ! -e "$T/race/fired" && \$("$REAL_CAT" "\$1" 2>/dev/null) == resume ]]; then
  touch "$T/race/fired"; echo stop > "$T/run/control.tmp" && mv -f "$T/run/control.tmp" "$T/run/control"
fi
exit \$rc
EOF
chmod +x "$T/race/cat"
PATH=$T/race:$T/slow:$PATH setsid bash "$ENGINE" run & started
ctl pause
for _ in $(seq 20); do [[ $(st state) == paused ]] && break; sleep 0.5; done
np=$(st done_count); ctl resume
for _ in $(seq 40); do [[ $(st state) == running || $(st state) == paused ]] || break; sleep 0.5; done
check "a stop sent right after resume is kept" '[[ $(st state) == stopped ]] && (( $(st done_count) - np <= 1 ))'
pid=$(cat "$T/run/pid" 2>/dev/null); [[ -n $pid ]] && kill -TERM -- "-$pid" 2>/dev/null; sleep 1.5

echo "== the current move shows its rsync command"
make_fixture extra
rm -f "$T/slow.argv"
PATH=$T/slow:$PATH setsid bash "$ENGINE" run & started
shown=""; want=""; shown_argv=()
for _ in $(seq 40); do   # until rsync runs and the dashboard shows a command; between two moves they can differ for an instant
  shown=$(php "$STATUS" | python3 -c 'import json,sys; c=json.load(sys.stdin)["current"]; print(c.get("cmd", "") if c else "")' 2>/dev/null)
  shown_argv=(); eval "shown_argv=($shown)" 2>/dev/null
  want=$(cat "$T/slow.argv" 2>/dev/null)
  [[ -n $shown && -n $want && $(printf '%s\n' "${shown_argv[@]}") == "$want" ]] && break
  sleep 0.25
done
check "Now moving shows the rsync command that is running" '[[ -n $shown && -n $want && $(printf "%s\n" "${shown_argv[@]}") == "$want" ]]'
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
