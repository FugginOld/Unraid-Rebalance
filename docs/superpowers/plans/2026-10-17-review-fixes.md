# Data Move review fixes (branch `dev`, tip 176022c)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. Dispatch each task to the `executor` agent (it pins its own model); the checkpoint is run by the main session with the user.

**Goal:** fix the confirmed findings of the branch review of the Data Move feature (swap between ticked disks, silent leftovers, a summary that hides left-out items, parent-path conflicts, a symlinked source parent, hardlink sizing, a misleading error text), document what stays as is, and prepare the changelog. Finding #7 (selection.tsv race) is deferred, with the reason under Decisions.

**Spec:** `docs/superpowers/specs/2026-10-07-data-move-design.md` (D1-D7 stand). Previous plan: `docs/superpowers/plans/2026-10-07-data-move.md` (its Global Constraints and commands are repeated below so this file stands alone).

**Pre-validation (2026-10-17):** every task below was applied to a scratch copy of tip 176022c and run in the `rebalance-test` image: each "expect FAIL" list is exactly what the old code printed, each task then passed in full (check counts below), every mutation `sed` changes its file and produces the named FAIL, `tests/syntax.sh` passed, and the Checkpoint's box block was run in Docker against the old engine (shows every bug) and the new one (shows every fix). A failure while executing therefore points at a transcription slip first.

---

## Constraints

- All files ship to Unraid: **LF line endings** (`.gitattributes`: `* text=auto eol=lf`). After editing any file run `grep -c $'\r' <file>` (as its own command, not inside `"$( )"`); it must print `0`.
- `rsync_argv` is not touched (`--remove-source-files --relative` stay adjacent; `status.php` finds rsync by that string).
- `RB_*` environment variables are test hooks only.
- Nothing new on the box: bash, PHP, rsync, find, du.
- **The rebalance modes (`plan`/`run`) must not change.** Every engine change below is inside the Data Move section (`read_selection`, `unit_conflict`, `expand_units`, `plan_move`), behind `$MOVE`, or in the EXECUTE failure text (shared, Task 7, text only). `item_paths` and `build_candidates` stay as they are.
- Existing checks must keep passing, including the hidden-name and newline/tab checks (`== a newline or tab in a parent folder at item depth 2`, `browse.php lists a folder with sizes`). No existing check is edited except where a step says so.
- Fixtures are evidence: never edit an existing fixture or expected value to make a check pass. If an existing check fails, STOP: **NEEDS JUDGEMENT**.
- Branch `dev` only. Commit after each task. **No push in any task; never touch `main`.** End every commit message with the attribution trailer your harness specifies.
- Tasks run strictly in order 1 → 8 (they all edit `rebalance.sh` and/or `tests/engine_test.sh`; see "Files per task").

### Commands used throughout

Run from Git Bash. The sandbox has no rsync, so tests run in the local Docker image `rebalance-test` (Ubuntu 24.04 + rsync 3.2.7, php-cli, python3, nodejs). The repo is mounted read-only at `/src`.

- `IN_DOCKER '<cmd>'` =
  `MSYS_NO_PATHCONV=1 docker run --rm -v "C:/Users/Joe/Documents/GitHub/Unraid-Rebalance:/src:ro" -w /src rebalance-test bash -c '<cmd>' 2>&1`
  If `docker image inspect rebalance-test` fails, rebuild it:
  ```bash
  docker build -q -t rebalance-test - <<'EOF'
  FROM ubuntu:24.04
  RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsync php-cli python3 nodejs xz-utils >/dev/null
  EOF
  ```
- `RUN_TESTS` = `IN_DOCKER 'bash tests/engine_test.sh' | awk '/^  ok/{n++} /^  FAIL|all checks passed|check\(s\) failed/{print} END{print n+0, "ok"}'`
  Prints every FAIL line, the verdict, and the number of passing checks. **Baseline at 176022c: `all checks passed`, `102 ok`.**
- `RUN_SYNTAX` = `IN_DOCKER 'bash tests/syntax.sh' | tail -1` → pass = `syntax ok`.
- Paths (repo root `/c/Users/Joe/Documents/GitHub/Unraid-Rebalance`):
  `ENG=source/usr/local/emhttp/plugins/rebalance/scripts/rebalance.sh`,
  `INC=source/usr/local/emhttp/plugins/rebalance/include`,
  `PLUG=source/usr/local/emhttp/plugins/rebalance`. Set them in the shell (`ENG=...; INC=...; PLUG=...`) before running a mutation `sed`.
- **Edits** are given as exact `old` → `new` text. Use the Edit tool with the `old` text as `old_string`. If an `old` text is not found exactly once: STOP, **NEEDS JUDGEMENT** (the file changed since this plan).
- **Test inserts:** "insert before the browse.php section" means: Edit with old_string
  ```
  echo "== browse.php"
  make_fixture
  ```
  and new_string = the given block, then a blank line, then those same two lines. Each task's block therefore lands after the previous task's block.
- **Mutation procedure** (each task's last step): the task is committed first. For each mutation: run the `sed` from the repo root, confirm `git diff --stat` shows `1 file changed`, run `RUN_TESTS`, confirm every listed `  FAIL  <name>` line appears, then `git checkout -- <file>`. Finish with `git status --short` printing nothing. If a `sed` changes nothing, or a listed FAIL does not appear: STOP, **NEEDS JUDGEMENT** (the test does not guard what it claims).

### Executor routing

- **Tasks 1-8: `executor`, unattended** — each is transcription plus a check; all code, tests, commands and expected output are written down. The executor stops and reports on any NEEDS JUDGEMENT trigger above.
- **Checkpoint (after Task 5): main session + user** — needs the user's consent for the push, generates the install block, and waits for pasted output. Not an executor step.
- **Final review: `reviewer`** on `git diff 176022c..dev` after Task 8.

---

## Decisions made in this plan

1. **#1 swap rule** — before placement, the engine records every candidate unit's path on its disk (`TICKED["disk|path"]=1`) and every folder above it (`=2`). A destination is refused for a unit when it holds a ticked unit at the same path, inside it, or above it (`ticked_near`). The set includes units that are later PLAN-SKIPped (conservative: a skipped unit stays where it is, so sending the same path there would still merge into ticked data). When every destination is refused, the unit is a PLAN-NOFIT (the plan fails, D5); the NOFIT log text now also names this reason. The client `plan()` mirrors it with a `held` map and `near()`.
2. **#2 loose files and odd names (user decision: loose files become units; odd names warn)** — expanding a ticked disk/share/folder above `ITEM_DEPTH` now walks every level down to item depth: every entry at item depth is a unit (as before), and every **non-folder** above item depth (file or symlink) is its own unit. Folders above item depth are only walked; one with nothing in it at item depth and no loose files moves nothing (it is empty or holds only left-behind entries). Hidden names (`.*`) and names containing a tab or newline, met at any level of that walk, are pruned (never descended into), **not moved**, counted, and logged as `PLAN-LEFT  <path>  (<why>)` — the first 50, then one `PLAN-LEFT  ... and N more, not listed` line. They do not fail the plan.
3. **Whole disk, disk root** (extends #2): at the root of a ticked disk, a hidden entry, a name with a tab/newline, a non-folder ("not in a share") and a share excluded in settings are each left behind and logged the same way (D5: "nothing is silently left out"). Root files stay unmoved because they are not share content (browse.php already shows them as untickable "not in a share" rows). Consequence: emptying a disk that holds `system`/`appdata` now ends as a warning that counts them — accurate, the disk is not empty.
4. **#2(c) preview** — `units()` now treats every non-excluded child as a unit candidate (files above item depth included). Hidden and tab/newline names never reach the browser (`browse.php` does not list them), so the preview cannot count them; the dry run is exact: its message gains `; N left behind (...)` and the log box colours `PLAN-LEFT` lines like skips.
5. **#3 / #2(b) final summary** — for a Data Move run (`$MOVE`) with `plan_skipped + plan_left > 0`, the final message gains `, N left out` and/or `, N left behind`, then ` - see log`; `warn=1` is set; a `done` run notifies at level `warning`. A `stopped` run gets the same text but keeps the `normal` notification (the UI shows warn only for `done`). Rebalance runs are unchanged.
6. **#4 parent conflicts** — `unit_conflict` first walks every parent of `rel` on the destination; a parent that is a symlink, or exists and is not a folder, is a conflict. `unit_conflict` is already called at plan time (against the destination and against every other source sending the same item folder) and live in EXECUTE right before each move's other checks, so one change covers both. The reason texts are unchanged (existing checks grep them).
7. **#5 symlinked source parent** — the realpath of the item's parent folder must equal `<realpath of the disk>/<literal parent>`, in the engine (`die "Bad selection: ... has a symlink above it"`) and in `action.php` (`"<key> has a symlink above it"`, 400). A ticked item that is itself a link is unchanged (moved as a link, or refused when it resolves outside its disk).
8. **#6 sizing** — `du -skl` (one process) instead of one `du` per unit. A file hardlinked twice inside one unit is then counted twice (over-estimate: the safe direction for the free-space check).
9. **#7 deferred** — the only reader of `selection.tsv` is the engine, once, at plan start. Overwriting it while a run is active (POST, then `rebalance-ctl` refuses) does not affect that run. The only harmful window is a second start inside the first second of a run (before the engine writes its pid and reads the selection); the proposed `selection.new` + rename-after-lock does not close that window, it moves it. Closing it needs a per-request selection file passed through `rebalance-ctl` to the engine (three files plus tests) — not "simple". Listed under Risks.
10. **#8 text** — the failure reason when rsync exits 0 but the source remains is `source still present - did a file appear on the destination?` (a dash instead of the review's inner parentheses, because the die text already wraps the reason in parentheses: `Move failed (<reason>): <path> -> <disk> - stopping`). History records the same reason. Emptied parent folders stay (documented in README); the browse.php non-UTF-8 behaviour is documented, no code change.
11. **#9 version entity — deviation from the request, confirm with the user:** Task 8 adds the CHANGES block only and does **not** bump `<!ENTITY version>`. The repo's own release procedure (`.github/workflows/release.yml` lines 3-10) has CI patch `version` and `md5` at tag time, and history shows exactly that split (`76235c6 Changelog for 2026.09.28` touched CHANGES only; `1c7d3b8 Release 2026.09.28`, the CI commit, bumped version + md5). A hand bump on `dev` would, once merged to `main`, advertise to every Unraid client a version whose package does not exist with an md5 that does not match. Repo docs outrank the global defaults; if the user still wants the bump, it is one line and must land together with a real package.

### Corrections to the review

- The `rebalance-ctl` refusal cited as `rebalance-ctl:161` is at line 20 (the file has 37 lines).
- Line numbers in the findings refer to tip 176022c; edits below are anchored on text, not line numbers.

---

## Steps

### Task 1: Two ticked disks never swap the same path (#1)

**Files:** `$ENG` (`declare` line, new `ticked_near`, `plan_move`), `$PLUG/DataMove.page` (`plan()`), `tests/engine_test.sh`.

- [ ] **Step 1: Failing tests** — insert before the browse.php section:

```bash
echo "== data move: two ticked disks never swap the same path"
make_fixture
mv "$T/mnt/disk2/tv/Show A (2001)/data.bin" "$T/mnt/disk2/tv/Show A (2001)/e02.bin"
touch -h -d '2 hours ago' "$T/mnt/disk2/tv/Show A (2001)"
sel $'item\tdisk1\ttv/Show A (2001)' $'item\tdisk2\ttv/Show A (2001)' $'dest\tdisk1' $'dest\tdisk2' $'dest\tdisk3'
bash "$ENGINE" move-plan; rc=$?
check "the same path ticked on two destination disks gathers on a third, never swaps" '[[ $rc == 0 && $(st state) == planned && $(cut -f3,4 "$T/run/plan.tsv") == "$(printf "disk1\tdisk3\ndisk2\tdisk3")" ]]'
echo 9000 > "$T/sizes/disk1"   # disk1 now has the most room: only the swap rule keeps the file off it
sel $'item\tdisk1\ttv/Show A (2001)' $'item\tdisk2\ttv/Show A (2001)/e02.bin' $'dest\tdisk1' $'dest\tdisk2' $'dest\tdisk3'
bash "$ENGINE" move-plan; rc=$?
check "a ticked folder and a ticked file inside it on another disk never swap" '[[ $rc == 0 && $(st state) == planned && $(cut -f3,4 "$T/run/plan.tsv") == "$(printf "disk1\tdisk3\ndisk2\tdisk3")" ]]'
sel $'item\tdisk1\ttv/Show A (2001)' $'item\tdisk2\ttv/Show A (2001)' $'dest\tdisk1' $'dest\tdisk2'
bash "$ENGINE" move-plan; rc=$?
check "with only the two ticked disks as destinations the plan fails instead of swapping" '[[ $rc == 1 && $(st state) == error ]] && grep -q "PLAN-NOFIT.*disk1/tv/Show A (2001)" "$T/rb.log"'
```

- [ ] **Step 2: Run — expect FAIL.** `RUN_TESTS` must print exactly these FAIL lines, then `3 check(s) failed` and `102 ok`:
  - `  FAIL  the same path ticked on two destination disks gathers on a third, never swaps`
  - `  FAIL  a ticked folder and a ticked file inside it on another disk never swap`
  - `  FAIL  with only the two ticked disks as destinations the plan fails instead of swapping`

- [ ] **Step 3: Implement.** Five edits in `$ENG`:

old:
```
SEL_ITEMS=(); SEL_DESTS=(); declare -A FULL_SRC
```
new:
```
SEL_ITEMS=(); SEL_DESTS=(); declare -A FULL_SRC TICKED
```

old (end of `unit_conflict`, start of `expand_units`):
```
  return 1
}
expand_units() {
```
new:
```
  return 1
}
ticked_near() {   # disk rel -> 0 when disk holds a ticked unit at rel, inside rel or above it (TICKED: 1 = a unit's path, 2 = a folder above one): sending rel there would swap data between two ticked disks
  local p=$2
  [[ -n ${TICKED["$1|$p"]} ]] && return 0
  while [[ $p == */* ]]; do p=${p%/*}; [[ ${TICKED["$1|$p"]} == 1 ]] && return 0; done
  return 1
}
expand_units() {
```

old:
```
  expand_units
  while IFS=$'\t' read -r -d '' sz path; do
    d=${path#"$MNT/"}; d=${d%%/*}; rel=${path#"$MNT/$d/"}; share=${rel%%/*}
    why=""
```
new:
```
  expand_units
  while IFS=$'\t' read -r -d '' sz path; do   # where the ticked data sits now, before anything is placed
    d=${path#"$MNT/"}; d=${d%%/*}; rel=${path#"$MNT/$d/"}
    TICKED["$d|$rel"]=1
    while [[ $rel == */* ]]; do rel=${rel%/*}; TICKED["$d|$rel"]=2; done
  done < "$RUN/cand.units"
  while IFS=$'\t' read -r -d '' sz path; do
    d=${path#"$MNT/"}; d=${d%%/*}; rel=${path#"$MNT/$d/"}; share=${rel%%/*}
    why=""
```

old:
```
      [[ -n ${FULL_SRC[$r]} ]] && continue             # D3: never onto a disk ticked in full
```
new:
```
      [[ -n ${FULL_SRC[$r]} ]] && continue             # D3: never onto a disk ticked in full
      ticked_near "$r" "$rel" && continue              # never onto a disk holding a ticked unit at, inside or above this path: no swap
```

old:
```
(no ticked disk has room above the minimum free space)"
```
new:
```
(no ticked disk has room above the minimum free space, other than ones holding a ticked item at this path)"
```

One edit in `$PLUG/DataMove.page` (`plan()`):

old:
```
    us.forEach(function (u) { outgoing[u.n.disk] += u.n.kib; srcs[u.n.disk] = 1; });
    var dests = disks().filter(function (x) { return DEST[x.name] && !full[x.name]; });
    us.forEach(function (u) {
      var n = u.n, item = itemOf(n.rel), best = null, bestHas = false;
      dests.forEach(function (x) {
        if (x.name === n.disk || room[x.name] < n.kib) return;
```
new:
```
    var held = {};   // "disk|path": 1 = a unit's path, 2 = a folder above one (the engine's TICKED)
    us.forEach(function (u) {
      outgoing[u.n.disk] += u.n.kib; srcs[u.n.disk] = 1; held[u.n.disk + '|' + u.n.rel] = 1;
      for (var p = u.n.rel; p.indexOf('/') !== -1; ) { p = p.slice(0, p.lastIndexOf('/')); held[u.n.disk + '|' + p] = 2; }
    });
    function near(disk, rel) {   // the engine's ticked_near: disk holds a ticked unit at, inside or above rel, so sending rel there would swap
      if (held[disk + '|' + rel]) return true;
      for (var p = rel; p.indexOf('/') !== -1; ) { p = p.slice(0, p.lastIndexOf('/')); if (held[disk + '|' + p] === 1) return true; }
      return false;
    }
    var dests = disks().filter(function (x) { return DEST[x.name] && !full[x.name]; });
    us.forEach(function (u) {
      var n = u.n, item = itemOf(n.rel), best = null, bestHas = false;
      dests.forEach(function (x) {
        if (x.name === n.disk || room[x.name] < n.kib || near(x.name, n.rel)) return;
```

- [ ] **Step 4: Run — expect PASS.** `RUN_TESTS` → `all checks passed`, `105 ok`. `RUN_SYNTAX` → `syntax ok`. `grep -c $'\r' "$ENG"` and `grep -c $'\r' "$PLUG/DataMove.page"` → `0` each.

- [ ] **Step 5: Commit** — `git add "$ENG" "$PLUG/DataMove.page" tests/engine_test.sh && git commit -m "Data Move: never send a path to a disk that holds a ticked item at that path (no swap)"`

- [ ] **Step 6: Mutations** (file `$ENG`):
```bash
sed -i '/# never onto a disk holding a ticked unit/d' "$ENG"
```
→ all three FAIL lines of Step 2.
```bash
sed -i '/== 1 \]\] && return 0; done/d' "$ENG"
```
→ `  FAIL  a ticked folder and a ticked file inside it on another disk never swap`
```bash
sed -i '/TICKED\["\$d|\$rel"\]=2; done/d' "$ENG"
```
→ `  FAIL  a ticked folder and a ticked file inside it on another disk never swap`

The `DataMove.page` mirror has no JS test harness; `RUN_SYNTAX` proves it parses and the Checkpoint's UI step proves the preview.

---

### Task 2: Loose files above Item depth move; odd names are left behind and logged (#2)

**Files:** `$ENG` (new `left_behind`, `expand_dir`; `expand_units`; `plan_move` summary; final summary), `$PLUG/DataMove.page` (`units()`), `$INC/common.js` (log colour), `tests/engine_test.sh`.

- [ ] **Step 1: Failing tests** — insert before the browse.php section:

```bash
echo "== data move: files and links above Item depth move as their own units"
make_fixture
echo 'ITEM_DEPTH="2"' >> "$T/rb.cfg"
echo loose > "$T/mnt/disk1/tv/loose.nfo"; ln -s ../movies "$T/mnt/disk1/tv/movies link"
find "$T/mnt/disk1/tv" -exec touch -h -d '2 hours ago' {} +
sel $'item\tdisk1\ttv' $'dest\tdisk3'
bash "$ENGINE" move-run; rc=$?
check "a file above Item depth in a ticked share moves" '[[ $rc == 0 && $(st state) == done && $(cat "$T/mnt/disk3/tv/loose.nfo" 2>/dev/null) == loose && ! -e $T/mnt/disk1/tv/loose.nfo ]]'
check "a link above Item depth in a ticked share moves as a link" '[[ -L "$T/mnt/disk3/tv/movies link" && ! -L "$T/mnt/disk1/tv/movies link" ]]'

echo "== data move: hidden entries, odd names and files outside shares are left behind, with a warning"
make_fixture
sed -i 's/NOTIFY="false"/NOTIFY="true"/' "$T/rb.cfg"
TAB=$'\t'
mkdir -p "$T/mnt/disk2/.Recycle.Bin" "$T/mnt/disk2/movies/Odd${TAB}Name"
echo h > "$T/mnt/disk2/movies/.hidden"; echo r > "$T/mnt/disk2/.Recycle.Bin/r"; echo z > "$T/mnt/disk2/rootfile"; echo t > "$T/mnt/disk2/movies/Odd${TAB}Name/t"
find "$T/mnt/disk2" -exec touch -h -d '2 hours ago' {} +
sel $'item\tdisk2\t' $'dest\tdisk3'
bash "$ENGINE" move-run; rc=$?
check "a whole disk still moves its shares' items" '[[ $rc == 0 && $(st state) == done && -d "$T/mnt/disk3/movies/Movie Three" && ! -e "$T/mnt/disk2/movies/Movie Three" ]]'
check "hidden entries, odd names and files outside shares stay, each logged" '[[ -f $T/mnt/disk2/movies/.hidden && -f $T/mnt/disk2/.Recycle.Bin/r && -f $T/mnt/disk2/rootfile && -f "$T/mnt/disk2/movies/Odd${TAB}Name/t" && $(grep -c "PLAN-LEFT" "$T/rb.log") == 4 ]]'
check "a move that leaves things behind ends as a warning that says so" '[[ $(st warn) == 1 && $(st msg) == *"4 left behind"* ]] && grep -q -- "-i warning" "$T/notify.log"'

echo "== data move: the left-behind list in the log is capped"
make_fixture
for i in $(seq 55); do touch "$T/mnt/disk2/movies/.h$i"; done
find "$T/mnt/disk2" -exec touch -h -d '2 hours ago' {} +
sel $'item\tdisk2\tmovies' $'dest\tdisk3'
bash "$ENGINE" move-plan; rc=$?
check "the log names 50 left-behind entries, then counts the rest" '[[ $rc == 0 && $(st state) == planned && $(grep -c "PLAN-LEFT  /" "$T/rb.log") == 50 && $(st msg) == *"55 left behind"* ]] && grep -q "PLAN-LEFT  \.\.\. and 5 more" "$T/rb.log"'
```

- [ ] **Step 2: Run — expect FAIL.** `RUN_TESTS` must print exactly these FAIL lines, then `5 check(s) failed` and `106 ok` (`a whole disk still moves its shares' items` passes on the old code; it guards the rewrite):
  - `  FAIL  a file above Item depth in a ticked share moves`
  - `  FAIL  a link above Item depth in a ticked share moves as a link`
  - `  FAIL  hidden entries, odd names and files outside shares stay, each logged`
  - `  FAIL  a move that leaves things behind ends as a warning that says so`
  - `  FAIL  the log names 50 left-behind entries, then counts the rest`

- [ ] **Step 3: Implement.** Five edits in `$ENG`:

old:
```
expand_units() {   # SEL_ITEMS -> $RUN/cand.units ("kib<TAB>path" NUL records, largest first). A whole disk, a share or a folder above ITEM_DEPTH splits into its items; a deeper folder or any file is one unit
  local a d rel share n dir
  for a in "${SEL_ITEMS[@]}"; do
    d=${a%%$'\t'*}; rel=${a#*$'\t'}; share=${rel%%/*}
    if [[ -n $share ]] && ! share_eligible "$share"; then
      log "PLAN-SKIP  $MNT/$d/$rel  (share excluded in settings)" >&2; (( plan_skipped++ )); continue
    fi
    n=${rel//[!\/]/}; n=$(( ${#n} + 1 )); [[ -z $rel ]] && n=0   # path depth: 0 = the whole disk, 1 = a share
    if (( n == 0 )); then
      for dir in "$MNT/$d"/*/; do
        [[ -d $dir ]] || continue
        share=${dir%/}; share=${share##*/}
        share_eligible "$share" && item_paths "$MNT/$d/$share" "$ITEM_DEPTH"
      done
    elif (( n <= ITEM_DEPTH )) && [[ -d $MNT/$d/$rel && ! -L $MNT/$d/$rel ]]; then
      item_paths "$MNT/$d/$rel" $(( ITEM_DEPTH + 1 - n ))
    else
```
new:
```
left_behind() {   # path why -> counted in plan_left and, for the first 50, logged as PLAN-LEFT. The entry is never moved
  (( plan_left++ < 50 )) && log "PLAN-LEFT  ${1//[$'\n\t']/?}  ($2)" >&2
  return 0
}
expand_dir() {   # dir k -> NUL-separated units below dir: every entry k levels down, and every file or link above that. Hidden names and names with a tab or newline are left behind
  local rec t y
  while IFS= read -r -d '' rec; do
    t=${rec%% *}; rec=${rec#* }
    if [[ $t == L ]]; then left_behind "$rec" "hidden, or a tab or newline in the name"; continue; fi
    y=${rec%% *}; rec=${rec#* }
    if (( t == $2 )) || [[ $y != d ]]; then printf '%s\0' "$rec"; fi   # a folder above depth k is walked, never moved whole
  done < <(find "$1" -mindepth 1 -maxdepth "$2" \( -name '.*' -o -name $'*\n*' -o -name $'*\t*' \) -prune -printf 'L %p\0' -o -printf '%d %y %p\0')
}
expand_units() {   # SEL_ITEMS -> $RUN/cand.units ("kib<TAB>path" NUL records, largest first). A whole disk, a share or a folder above ITEM_DEPTH splits into its items plus any file or link above item depth; a deeper folder or any file is one unit
  local a d rel share n p
  for a in "${SEL_ITEMS[@]}"; do
    d=${a%%$'\t'*}; rel=${a#*$'\t'}; share=${rel%%/*}
    if [[ -n $share ]] && ! share_eligible "$share"; then
      log "PLAN-SKIP  $MNT/$d/$rel  (share excluded in settings)" >&2; (( plan_skipped++ )); continue
    fi
    n=${rel//[!\/]/}; n=$(( ${#n} + 1 )); [[ -z $rel ]] && n=0   # path depth: 0 = the whole disk, 1 = a share
    if (( n == 0 )); then   # a whole disk: each eligible share expands; nothing else at the disk root moves
      while IFS= read -r -d '' p; do
        share=${p##*/}
        if [[ $share == .* || $share == *[$'\n\t']* ]]; then left_behind "$p" "hidden, or a tab or newline in the name"
        elif [[ ! -d $p || -L $p ]]; then left_behind "$p" "not in a share"
        elif ! share_eligible "$share"; then left_behind "$p" "share excluded in settings"
        else expand_dir "$p" "$ITEM_DEPTH"; fi
      done < <(find "$MNT/$d" -mindepth 1 -maxdepth 1 -print0)
    elif (( n <= ITEM_DEPTH )) && [[ -d $MNT/$d/$rel && ! -L $MNT/$d/$rel ]]; then
      expand_dir "$MNT/$d/$rel" $(( ITEM_DEPTH + 1 - n ))
    else
```

old:
```
  plan_count=0; plan_kib=0; plan_skipped=0
  : > "$RUN/plan.tsv"
  read_selection
  log "Scanning the selection (depth $ITEM_DEPTH)"
  expand_units
```
new:
```
  plan_count=0; plan_kib=0; plan_skipped=0; plan_left=0
  : > "$RUN/plan.tsv"
  read_selection
  log "Scanning the selection (depth $ITEM_DEPTH)"
  expand_units
  (( plan_left > 50 )) && log "PLAN-LEFT  ... and $(( plan_left - 50 )) more, not listed"
```

old:
```
  summary="$plan_count move(s), $(human "$plan_kib") planned; $plan_skipped item(s) left out (in-progress, hardlinked or excluded share)"
  log "Plan: $summary"
  if (( bad )); then   # D5: nothing moves while any ticked item cannot be placed
```
new:
```
  left=""; (( plan_left )) && left="; $plan_left left behind (hidden or odd names, outside a share or in an excluded share)"
  summary="$plan_count move(s), $(human "$plan_kib") planned; $plan_skipped item(s) left out (in-progress, hardlinked or excluded share)$left"
  log "Plan: $summary"
  if (( bad )); then   # D5: nothing moves while any ticked item cannot be placed
```

old:
```
    msg="Nothing can be moved - $plan_skipped item(s) left out (in-progress, hardlinked or excluded share), see log"
    (( plan_skipped )) || msg="Nothing to move - the ticked items hold nothing to move"
```
new:
```
    msg="Nothing can be moved - $plan_skipped item(s) left out (in-progress, hardlinked or excluded share)$left, see log"
    (( plan_skipped || plan_left )) || msg="Nothing to move - the ticked items hold nothing to move"
```

old:
```
summary="$done_count of $plan_count moved ($(human "$done_kib")), $skipped skipped"
if (( STOP_REQ )); then
  FINAL=stopped; st_set state stopped cur_idx 0 msg "Stopped by user: $summary"
  log "Stopped by user: $summary"; notify normal "Stopped: $summary"
else
  FINAL=done; st_set state done cur_idx 0 msg "$summary"
  log "Done: $summary"; notify normal "Done: $summary"
fi
```
new:
```
summary="$done_count of $plan_count moved ($(human "$done_kib")), $skipped skipped"
lvl=normal
if $MOVE && (( plan_left )); then summary+=", $plan_left left behind - see log"; st_set warn 1; lvl=warning; fi   # D5: a Data Move never leaves anything behind silently
if (( STOP_REQ )); then
  FINAL=stopped; st_set state stopped cur_idx 0 msg "Stopped by user: $summary"
  log "Stopped by user: $summary"; notify normal "Stopped: $summary"
else
  FINAL=done; st_set state done cur_idx 0 msg "$summary"
  log "Done: $summary"; notify "$lvl" "Done: $summary"
fi
```

Two edits in `$PLUG/DataMove.page` (`units()`):

old:
```
  function units() {   // what the engine plans: a ticked disk, share or folder above Item depth splits into its items
```
new:
```
  function units() {   // what the engine plans: a ticked disk, share or folder above Item depth splits into its items, plus any file or link above Item depth (files at the disk root are excluded rows: the engine leaves them behind)
```

old:
```
        n.kids.forEach(function (k) { if (!k.excluded && !(k.kind === 'file' && k.depth <= D)) add(k); });
```
new:
```
        n.kids.forEach(function (k) { if (!k.excluded) add(k); });
```

One edit in `$INC/common.js` (log colours):

old:
```
        var cls = /\bSKIP\b|PAUSED|WARNING/.test(line)
```
new:
```
        var cls = /\bSKIP\b|PLAN-LEFT|PAUSED|WARNING/.test(line)
```

- [ ] **Step 4: Run — expect PASS.** `RUN_TESTS` → `all checks passed`, `111 ok`. `RUN_SYNTAX` → `syntax ok`. `grep -c $'\r'` → `0` for `$ENG`, `$PLUG/DataMove.page`, `$INC/common.js`.

- [ ] **Step 5: Commit** — `git add "$ENG" "$PLUG/DataMove.page" "$INC/common.js" tests/engine_test.sh && git commit -m "Data Move: loose files above Item depth move; hidden and odd names are left behind, logged and warned"`

- [ ] **Step 6: Mutations** (file `$ENG`):
```bash
sed -i 's/if (( t == \$2 )) || \[\[ \$y != d \]\]; then/if (( t == $2 )); then/' "$ENG"
```
→ `  FAIL  a file above Item depth in a ticked share moves` and `  FAIL  a link above Item depth in a ticked share moves as a link`
```bash
sed -i 's/(( plan_left++ < 50 ))/(( plan_left++ < 0 ))/' "$ENG"
```
→ `  FAIL  hidden entries, odd names and files outside shares stay, each logged` and `  FAIL  the log names 50 left-behind entries, then counts the rest`
```bash
sed -i '/# D5: a Data Move never leaves anything behind silently/d' "$ENG"
```
→ `  FAIL  a move that leaves things behind ends as a warning that says so`
```bash
sed -i '/more, not listed/d' "$ENG"
```
→ `  FAIL  the log names 50 left-behind entries, then counts the rest`
```bash
sed -i 's/elif \[\[ ! -d \$p || -L \$p \]\]; then/elif false; then/' "$ENG"
```
→ `  FAIL  hidden entries, odd names and files outside shares stay, each logged` and `  FAIL  a move that leaves things behind ends as a warning that says so`

---

### Task 3: A move-run that left items out says so (#3)

**Files:** `$ENG` (final summary), `$INC/common.js` (comment), `tests/engine_test.sh`.

- [ ] **Step 1: Failing test** — insert before the browse.php section:

```bash
echo "== data move: a run that left items out says so"
make_fixture
sed -i 's/NOTIFY="false"/NOTIFY="true"/' "$T/rb.cfg"
sel $'item\tdisk1\t' $'dest\tdisk3' $'dest\tdisk4'   # disk1's hardlinked pair (Movie Two, downloads/seed.bin) is left out
bash "$ENGINE" move-run; rc=$?
check "a move-run that left items out ends as a warning that counts them" '[[ $rc == 0 && $(st state) == done && $(st warn) == 1 && $(st msg) == *", 2 left out - see log" ]] && grep -q -- "-i warning" "$T/notify.log" && ! grep -q -- "-i normal" "$T/notify.log"'
```

- [ ] **Step 2: Run — expect FAIL.** `RUN_TESTS` → exactly `  FAIL  a move-run that left items out ends as a warning that counts them`, `1 check(s) failed`, `111 ok`.

- [ ] **Step 3: Implement.** One edit in `$ENG`:

old:
```
if $MOVE && (( plan_left )); then summary+=", $plan_left left behind - see log"; st_set warn 1; lvl=warning; fi   # D5: a Data Move never leaves anything behind silently
```
new:
```
if $MOVE && (( plan_skipped + plan_left )); then   # D5: a Data Move never leaves anything out or behind silently
  (( plan_skipped )) && summary+=", $plan_skipped left out"
  (( plan_left )) && summary+=", $plan_left left behind"
  summary+=" - see log"; st_set warn 1; lvl=warning
fi
```

One edit in `$INC/common.js` (the comment no longer matches):

old:
```
      var warn = d.state === 'done' && d.warn;   // "Nothing can be moved": done, but a disk is still over target
```
new:
```
      var warn = d.state === 'done' && d.warn;   // done, but look: "Nothing can be moved", or a data move that left items out or behind
```

- [ ] **Step 4: Run — expect PASS.** `RUN_TESTS` → `all checks passed`, `112 ok`. `RUN_SYNTAX` → `syntax ok`. `grep -c $'\r'` → `0` for `$ENG` and `$INC/common.js`.

- [ ] **Step 5: Commit** — `git add "$ENG" "$INC/common.js" tests/engine_test.sh && git commit -m "Data Move: a run that left items out ends as a warning that counts them"`

- [ ] **Step 6: Mutations** (file `$ENG`):
```bash
sed -i 's/(( plan_skipped )) && summary+=/(( 0 )) \&\& summary+=/' "$ENG"
```
→ `  FAIL  a move-run that left items out ends as a warning that counts them`
```bash
sed -i 's/if \$MOVE && (( plan_skipped + plan_left )); then/if $MOVE \&\& (( plan_left )); then/' "$ENG"
```
→ `  FAIL  a move-run that left items out ends as a warning that counts them`
```bash
sed -i 's/notify "\$lvl" "Done: /notify normal "Done: /' "$ENG"
```
→ `  FAIL  a move that leaves things behind ends as a warning that says so` and `  FAIL  a move-run that left items out ends as a warning that counts them`

---

### Task 4: A file or link where the destination needs a folder is a conflict, at plan time and live (#4)

**Files:** `$ENG` (`unit_conflict`), `tests/engine_test.sh`.

- [ ] **Step 1: Failing tests** — insert before the browse.php section:

```bash
echo "== data move: a file or a link where the destination needs a folder above the item"
make_fixture
mkdir -p "$T/mnt/disk1/movies/Coll/Sub"; echo x > "$T/mnt/disk1/movies/Coll/Sub/f"
find "$T/mnt/disk1/movies/Coll" -exec touch -h -d '2 hours ago' {} +
echo y > "$T/mnt/disk3/movies/Coll"   # a file where the move needs the folder movies/Coll
sel $'item\tdisk1\tmovies/Coll/Sub' $'dest\tdisk3'
bash "$ENGINE" move-plan; rc=$?
check "a file at a parent path on the destination fails the dry run" '[[ $rc == 1 && $(st state) == error ]] && grep -q "PLAN-CONFLICT.*movies/Coll/Sub" "$T/rb.log"'
rm "$T/mnt/disk3/movies/Coll"; mkdir -p "$T/outside"; ln -s "$T/outside" "$T/mnt/disk3/movies/Coll"   # a link there: rsync would write through it
bash "$ENGINE" move-run; rc=$?
check "a link at a parent path on the destination fails the plan, nothing is written through it" '[[ $rc == 1 && $(st state) == error && -z $(ls -A "$T/outside") && -f "$T/mnt/disk1/movies/Coll/Sub/f" ]]'

echo "== data move: a file that appears at a parent path after planning is skipped live"
make_fixture
mkdir -p "$T/mnt/disk1/movies/Coll/Sub"; echo x > "$T/mnt/disk1/movies/Coll/Sub/f"
find "$T/mnt/disk1/movies/Coll" -exec touch -h -d '2 hours ago' {} +
mkdir -p "$T/lateparent"
cat > "$T/lateparent/rsync" <<EOF
#!/bin/bash
# while the first move copies, a file appears where the second unit needs the folder movies/Coll
echo late > "$T/mnt/disk3/movies/Coll"
exec "$REAL_RSYNC" "\$@"
EOF
chmod +x "$T/lateparent/rsync"
sel $'item\tdisk1\ttv/Show A (2001)' $'item\tdisk1\tmovies/Coll/Sub' $'dest\tdisk3'
PATH=$T/lateparent:$PATH bash "$ENGINE" move-run; rc=$?
check "a file that appears at a parent path is a live skip, not a failed rsync" '[[ $rc == 0 && $(st state) == done && $(st done_count) == 1 && $(st skipped) == 1 && -f "$T/mnt/disk1/movies/Coll/Sub/f" ]] && grep -q "SKIP.*movies/Coll/Sub" "$T/rb.log"'
```

- [ ] **Step 2: Run — expect FAIL.** `RUN_TESTS` → exactly these, then `3 check(s) failed`, `112 ok`:
  - `  FAIL  a file at a parent path on the destination fails the dry run`
  - `  FAIL  a link at a parent path on the destination fails the plan, nothing is written through it`
  - `  FAIL  a file that appears at a parent path is a live skip, not a failed rsync`

- [ ] **Step 3: Implement.** One edit in `$ENG`:

old:
```
unit_conflict() {   # src dst rel -> 0 when moving rel would meet a file at the same path on dst, or a file where a folder is (or the reverse)
  local s=$MNT/$1/$3 d=$MNT/$2/$3 t p
  [[ -e $d || -L $d ]] || return 1
```
new:
```
unit_conflict() {   # src dst rel -> 0 when moving rel would meet a file at the same path on dst, or a file where a folder is (or the reverse), or a file or link where dst needs a folder above rel
  local s=$MNT/$1/$3 d=$MNT/$2/$3 t p=$3
  while [[ $p == */* ]]; do p=${p%/*}; [[ -L $MNT/$2/$p || ( -e $MNT/$2/$p && ! -d $MNT/$2/$p ) ]] && return 0; done   # rsync would fail on a file there, or write through a link
  [[ -e $d || -L $d ]] || return 1
```

- [ ] **Step 4: Run — expect PASS.** `RUN_TESTS` → `all checks passed`, `115 ok`. `grep -c $'\r' "$ENG"` → `0`.

- [ ] **Step 5: Commit** — `git add "$ENG" tests/engine_test.sh && git commit -m "Data Move: a file or link at a parent path on the destination is a conflict, at plan time and live"`

- [ ] **Step 6: Mutations** (file `$ENG`):
```bash
sed -i '/# rsync would fail on a file there, or write through a link/d' "$ENG"
```
→ all three FAIL lines of Step 2.
```bash
sed -i 's/\[\[ -L \$MNT\/\$2\/\$p || /[[ /' "$ENG"
```
→ `  FAIL  a link at a parent path on the destination fails the plan, nothing is written through it`

---

### Task 5: Refuse an item whose parent folder is reached through a symlink (#5)

**Files:** `$ENG` (`read_selection`), `$INC/action.php`, `tests/engine_test.sh` (three edits in existing sections).

- [ ] **Step 1: Failing tests.** Three edits in `tests/engine_test.sh`:

old:
```
ln -s "$T/mnt/disk2/movies" "$T/mnt/disk1/escape"
while IFS='|' read -r line want; do
```
new:
```
ln -s "$T/mnt/disk2/movies" "$T/mnt/disk1/escape"
ln -s "$T/mnt/disk1/tv" "$T/mnt/disk1/movies/link"   # a link to another folder on the same disk
while IFS='|' read -r line want; do
```

old:
```
item\tdisk1\tescape|is outside disk1
bogus
```
new:
```
item\tdisk1\tescape|is outside disk1
item\tdisk1\tmovies/link/Show B|has a symlink above it
bogus
```

old:
```
check "action.php refuses an empty destination list" '[[ $j == *"\"ok\":false"* && $j == *destination* && ! -e $T/ctl.argv ]]'
```
new:
```
check "action.php refuses an empty destination list" '[[ $j == *"\"ok\":false"* && $j == *destination* && ! -e $T/ctl.argv ]]'
ln -s "$T/mnt/disk1/tv" "$T/mnt/disk1/movies/link"   # a link to another folder on the same disk
j=$(act action=move-plan 'items=[{"disk":"disk1","rel":"movies/link/Show B"}]' 'dests=["disk3"]')
check "action.php refuses an item with a symlink above it" '[[ $j == *"\"ok\":false"* && $j == *symlink* && ! -e $T/ctl.argv ]]'
rm -f "$T/ctl.argv"
```

- [ ] **Step 2: Run — expect FAIL.** `RUN_TESTS` → exactly these, then `2 check(s) failed`, `115 ok`:
  - `  FAIL  selection refused (has a symlink above it): item disk1 movies/link/Show B`
  - `  FAIL  action.php refuses an item with a symlink above it`

- [ ] **Step 3: Implement.** One edit in `$ENG`:

old:
```
    [[ $p == "$base" || $p == "$base"/* ]] || die "Bad selection: $MNT/$d/$rel is outside $d"
```
new:
```
    [[ $p == "$base" || $p == "$base"/* ]] || die "Bad selection: $MNT/$d/$rel is outside $d"
    [[ $rel != */* || $(realpath -e -- "$MNT/$d/${rel%/*}") == "$base/${rel%/*}" ]] || die "Bad selection: $MNT/$d/$rel has a symlink above it"   # the move goes to the literal path: a link above it would split one folder's content across two paths
```

One edit in `$INC/action.php`:

old:
```
    if ($root === false || $p === false || ($p !== $root && strpos($p, "$root/") !== 0)) reply(false, "$key no longer exists", 400);
```
new:
```
    if ($root === false || $p === false || ($p !== $root && strpos($p, "$root/") !== 0)) reply(false, "$key no longer exists", 400);
    if (($i = strrpos($r, '/')) !== false && realpath("$mnt/$d/" . substr($r, 0, $i)) !== "$root/" . substr($r, 0, $i)) reply(false, "$key has a symlink above it", 400);   /* the move goes to the literal path */
```

- [ ] **Step 4: Run — expect PASS.** `RUN_TESTS` → `all checks passed`, `117 ok`. `RUN_SYNTAX` → `syntax ok`. `grep -c $'\r'` → `0` for `$ENG` and `$INC/action.php`.

- [ ] **Step 5: Commit** — `git add "$ENG" "$INC/action.php" tests/engine_test.sh && git commit -m "Data Move: refuse an item whose parent folder is reached through a symlink"`

- [ ] **Step 6: Mutations:**
```bash
sed -i '/has a symlink above it"   # the move goes/d' "$ENG"
```
→ `  FAIL  selection refused (has a symlink above it): item disk1 movies/link/Show B` (revert with `git checkout -- "$ENG"`)
```bash
sed -i '/has a symlink above it", 400);/d' "$INC/action.php"
```
→ `  FAIL  action.php refuses an item with a symlink above it` (revert with `git checkout -- "$INC/action.php"`)

---

### Checkpoint: STOP — user installs Tasks 1-5 on the box and verifies (main session, not an executor)

Docker passes are not Unraid passes (shfs, Unraid's rsync/find/bash versions). One install, one read-only verification. Post **one block per message**, stop, wait for the pasted output.

**Before posting anything:** `git status --short` prints nothing; `RUN_TESTS` → `all checks passed`, `117 ok`; `RUN_SYNTAX` → `syntax ok`.

**Message 1 (state-changing):**
1. Ask the user to approve pushing `dev` to `origin/dev` (fast-forward only; never `main`). Push only after a yes in the user's own message.
2. Build the install block from the template used on 2026-10-17, `C:\Users\Joe\AppData\Local\Temp\claude\c--Users-Joe-Documents-GitHub-Unraid-Rebalance\05f0a85b-f3fa-4249-988b-abfb4b21fe74\scratchpad\install-block2.sh`: change only the `SHA=` line (full SHA of the pushed `dev` tip) and the `FILES` list, generated with
   ```bash
   cd /c/Users/Joe/Documents/GitHub/Unraid-Rebalance && SHA=$(git rev-parse dev) && git diff --name-only 1c7d3b8 "$SHA" -- source/ | while read -r p; do printf '%s  %s\n' "$(git show "$SHA:$p" | sha256sum | cut -c1-64)" "${p#source/usr/local/emhttp/plugins/rebalance/}"; done
   ```
   `KNOWN` is unchanged (this plan adds no file). If the template file is gone: STOP, **NEEDS JUDGEMENT** (rebuild it per Checkpoint I1 step 2 of `docs/superpowers/plans/2026-10-07-data-move.md`).
3. Pre-test the block locally against a fake plugin dir and the live raw URLs (idle, busy, tampered hash), then post it as the only block.

Pass: one `<file>: OK` line per listed file (`DataMove.page`, `include/action.php`, `include/common.js` and `scripts/rebalance.sh` are among them), and no `NOT IDLE`, `DOWNLOAD FAILED`, `HASH MISMATCH`, `VERIFY FAILED` or `EXTRA` line.

**Message 2 (read-only on the array):** runs the installed engine against a scratch fake array under `/tmp` (its own lock, run dir and log; a stub `df`; turbo write, parity pause and notifications off), then deletes the scratch dir. It does not touch `/mnt`, `/var/local/rebalance`, `/var/log/rebalance.log` or the md driver. It runs in a subshell, so nothing leaks into the user's shell.

```bash
( E=${E:-/usr/local/emhttp/plugins/rebalance/scripts/rebalance.sh}; T=$(mktemp -d /tmp/rb-verify.XXXXXX); M=$T/mnt
mkdir -p "$T/bin" "$T/run" "$T/cfg/shares" "$T/outside" "$M/disk3"
cat > "$T/bin/df" <<'EOF'
#!/bin/bash
for a in "$@"; do case $a in --output=*) f=${a#--output=};; -*) ;; *) p=$a;; esac; done
u=$(du -sk "$p" | cut -f1); echo hdr
if [ "$f" = avail ]; then echo $((100000-u)); else echo "100000 $u $((100000-u))"; fi
EOF
chmod +x "$T/bin/df"
printf 'MIN_FREE_GB="0"\nTURBO_WRITE="false"\nPAUSE_ON_PARITY="false"\nNOTIFY="false"\nSKIP_RECENT_MIN="0"\nSKIP_OPEN_FILES="false"\n' > "$T/rb.cfg"
printf 'mdState="STARTED"\nmdResyncPos="0"\n' > "$T/var.ini"
export PATH=$T/bin:$PATH RB_MNT=$M RB_RUN=$T/run RB_LOG=$T/rb.log RB_VAR_INI=$T/var.ini RB_SHARE_CFG=$T/cfg RB_CFG=$T/rb.cfg RB_NOTIFY_BIN=/bin/true
f() { mkdir -p "$(dirname "$M/$1")"; head -c "${2:-4096}" /dev/urandom > "$M/$1"; }
r() { printf '%s\n' "${@:3}" > "$T/run/selection.tsv"; bash "$E" "$2" >/dev/null 2>&1; rc=$?
  echo "$1 rc=$rc $(sed -n 's/^state=//p' "$T/run/status") warn=$(sed -n 's/^warn=//p' "$T/run/status") | $(cut -f3,4 "$T/run/plan.tsv" 2>/dev/null | tr '\t\n' '> ')| $(sed -n 's/^msg=//p' "$T/run/status" | cut -c1-110)"; }
f disk1/tv/Show/a 100000; f disk2/tv/Show/b 10000
r 1 move-plan $'item\tdisk1\ttv/Show' $'item\tdisk2\ttv/Show' $'dest\tdisk1' $'dest\tdisk2' $'dest\tdisk3'
f disk2/tv/.hidden; f disk2/.Recycle.Bin/r; f disk2/rootfile; f "disk2/tv/Odd"$'\t'"Name/t"
r 2 move-run $'item\tdisk2\t' $'dest\tdisk3'
f disk1/movies/M/f; mkdir -p "$M/disk1/dl"; ln "$M/disk1/movies/M/f" "$M/disk1/dl/s"; f disk1/movies/N/g
r 3 move-run $'item\tdisk1\tmovies' $'dest\tdisk3'
f disk1/films/Coll/Sub/f; mkdir -p "$M/disk3/films"; ln -s "$T/outside" "$M/disk3/films/Coll"
r 4 move-run $'item\tdisk1\tfilms/Coll/Sub' $'dest\tdisk3'; echo "4 written through the link: $(ls -A "$T/outside" | wc -l)"
ln -s "$M/disk1/tv" "$M/disk1/films/link"
r 5 move-plan $'item\tdisk1\tfilms/link/Show' $'dest\tdisk3'
echo "left on disk2: $(cd "$M/disk2" && ls -A . tv | tr '\t\n' '? ')"; rm -rf "$T" )
```

Pass — exactly 7 lines; sizes in parentheses may differ from Docker, everything else must match:
```
1 rc=0 planned warn= | disk1>disk3 disk2>disk3 | 2 move(s), ... planned; 0 item(s) left out (in-progress, hardlinked or excluded share)
2 rc=0 done warn=1 | disk2>disk3 | 1 of 1 moved (...), 0 skipped, 4 left behind - see log
3 rc=0 done warn=1 | disk1>disk3 | 1 of 1 moved (...), 0 skipped, 1 left out - see log
4 rc=1 error warn= | disk1>disk3 | 1 item(s) cannot be moved - they don't fit above the minimum free space or would overwrite a file. Nothing was
4 written through the link: 0
5 rc=1 error warn= | | Bad selection: /tmp/rb-verify.XXXXXX/mnt/disk1/films/link/Show has a symlink above it
left on disk2: .: .Recycle.Bin rootfile tv  tv: .hidden Odd?Name
```
The old engine prints `disk1>disk2 disk2>disk1` on line 1, no `left behind`/`left out` on lines 2-3, `rc=0 done` with `written through the link: 1` on line 4, and `rc=0 planned` on line 5: any of those means the install did not take. Any other difference: STOP, ask for `tail -30` of the scratch log by re-running with `rm -rf "$T"` replaced by `tail -30 "$T/rb.log"; rm -rf "$T"` — **NEEDS JUDGEMENT**.

**UI step (no command, same message as block 2's result):** hard-refresh **Settings → User Utilities → Array Rebalance → Data Move**. Pass: the page loads, the browser console shows no errors, and — if the user has a folder `F` present on two disks `A` and `B` — ticking `F` on both disks plus destinations `A`, `B` and a third disk `C` shows both `F` rows going to `C` in **Up next**; with only `A` and `B` ticked as destinations the preview shows them as "won't fit". Do not start a move.

---

### Task 6: Units that share a hardlinked file are each sized in full (#6)

**Files:** `$ENG` (`expand_units`, last line), `tests/engine_test.sh`.

- [ ] **Step 1: Failing test** — insert before the browse.php section:

```bash
echo "== data move: units that share a hardlinked file are each sized in full"
make_fixture
echo 'SKIP_HARDLINKED="false"' >> "$T/rb.cfg"   # both halves of disk1's hardlinked pair are planned
sel $'item\tdisk1\tmovies/Movie Two' $'item\tdisk1\tdownloads/seed.bin' $'dest\tdisk3'
bash "$ENGINE" move-plan; rc=$?
check "units that share a hardlinked file are each sized in full" '[[ $rc == 0 && $(st state) == planned && $(cut -f2 "$T/run/plan.tsv") == "$(printf "304\n300")" ]]'
```

- [ ] **Step 2: Run — expect FAIL.** `RUN_TESTS` → exactly `  FAIL  units that share a hardlinked file are each sized in full`, `1 check(s) failed`, `117 ok`.

- [ ] **Step 3: Implement.** One edit in `$ENG`:

old:
```
  xargs -0 -r du -sk --null -- < "$RUN/cand.sel" 2>/dev/null | sort -z -t$'\t' -k1,1nr > "$RUN/cand.units"
```
new:
```
  xargs -0 -r du -skl --null -- < "$RUN/cand.sel" 2>/dev/null | sort -z -t$'\t' -k1,1nr > "$RUN/cand.units"   # -l: a file hardlinked into two units counts in each (one du run would count it once)
```

- [ ] **Step 4: Run — expect PASS.** `RUN_TESTS` → `all checks passed`, `118 ok` (the existing hardlink checks `hardlinked items left out (2)` and the stuck-dry-run checks stay `ok`). `grep -c $'\r' "$ENG"` → `0`.

- [ ] **Step 5: Commit** — `git add "$ENG" tests/engine_test.sh && git commit -m "Data Move: size each unit in full when units share a hardlinked file"`

- [ ] **Step 6: Mutation:**
```bash
sed -i 's/du -skl --null/du -sk --null/' "$ENG"
```
→ `  FAIL  units that share a hardlinked file are each sized in full`

---

### Task 7: Name the real cause of a "source still present" stop; document what stays (#8)

**Files:** `$ENG` (EXECUTE failure branch), `tests/engine_test.sh`, `README.md`.

- [ ] **Step 1: Failing test.** One edit in `tests/engine_test.sh` (section `== a file that appears on the destination during a move is never overwritten`):

old:
```
check "the source copy is kept" '[[ $(stat -c %s "$T/mnt/disk1/movies/Movie One (2020)/data.bin" 2>/dev/null) == 409600 ]]'
```
new:
```
check "the source copy is kept" '[[ $(stat -c %s "$T/mnt/disk1/movies/Movie One (2020)/data.bin" 2>/dev/null) == 409600 ]]'
check "the error says the source is still there, not a bare rsync exit 0" '[[ $(st msg) == "Move failed (source still present - did a file appear on the destination?): "* ]] && grep -q "	fail	source still present" "$T/run/history.tsv"'
```
(The `grep -q` pattern contains two literal TAB characters, before and after `fail`, exactly as the existing check `history records the move` does. If the Edit tool cannot type a TAB, write the pattern as `"$(printf "\tfail\tsource still present")"`.)

- [ ] **Step 2: Run — expect FAIL.** `RUN_TESTS` → exactly `  FAIL  the error says the source is still there, not a bare rsync exit 0`, `1 check(s) failed`, `118 ok`.

- [ ] **Step 3: Implement.** One edit in `$ENG`:

old:
```
    history "$idx" fail "rsync exit $rc" "$sz" "$src" "$dst" "$t0" "$EPOCHSECONDS" "$rel"
    die "Move failed (rsync exit $rc): $MNT/$src/$rel -> $dst - stopping"
```
new:
```
    why="rsync exit $rc"; (( rc )) || why="source still present - did a file appear on the destination?"   # rsync --ignore-existing skips such a file and exits 0
    history "$idx" fail "$why" "$sz" "$src" "$dst" "$t0" "$EPOCHSECONDS" "$rel"
    die "Move failed ($why): $MNT/$src/$rel -> $dst - stopping"
```

One edit in `README.md` (documentation of #2, #8 and the browse.php non-UTF-8 case; no code change for either):

old:
```
**Dry run** only builds the plan. **Start rebalance** rebuilds the plan from current usage, then executes it.
```
new:
```
**Dry run** only builds the plan. **Start rebalance** rebuilds the plan from current usage, then executes it.

**Data Move** (second tab) sends the ticked disks, folders or files to the ticked disks, keeping their paths. A ticked disk, share or folder above `ITEM_DEPTH` splits into its items, plus any file or link that sits above that depth. Items go largest first onto a ticked disk that already holds their folder, else the one with the most room; never back to their own disk, onto a disk ticked in full, or onto a disk that holds a ticked item at the same path. A same-named file on the destination, or a file or link where a folder is needed, fails the dry run and nothing moves. Never moved: hidden entries (such as `.Recycle.Bin`), names containing a tab or line break, files at the disk root and shares excluded in settings — the log lists them as `PLAN-LEFT` and the result is a warning. Folders emptied by a move stay on the source disk; delete them by hand if you want. A name that is not valid UTF-8 shows with `�` in the Source tree and cannot be opened or ticked on its own (the page says it no longer exists); tick its parent folder instead.
```

- [ ] **Step 4: Run — expect PASS.** `RUN_TESTS` → `all checks passed`, `119 ok`. `RUN_SYNTAX` → `syntax ok`. `grep -c $'\r'` → `0` for `$ENG`, `tests/engine_test.sh`, `README.md`. `grep -c 'PLAN-LEFT' README.md` → `1`.

- [ ] **Step 5: Commit** — `git add "$ENG" tests/engine_test.sh README.md && git commit -m "Say 'source still present' when a move stops on a file that appeared on the destination; document Data Move leftovers"`

- [ ] **Step 6: Mutation:**
```bash
sed -i 's/(( rc )) || why="source still present/(( 1 )) || why="source still present/' "$ENG"
```
→ `  FAIL  the error says the source is still there, not a bare rsync exit 0`

---

### Task 8: Release prep — CHANGES block only (#9)

**This task must NOT tag, create a release, push, or merge to `main`, and does not bump `<!ENTITY version>` (Decision 11).** It commits on `dev` only.

**Files:** `rebalance.plg` (`<CHANGES>` only).

- [ ] **Step 1: Choose the version and prove it is absent.** Run:
  ```bash
  cd /c/Users/Joe/Documents/GitHub/Unraid-Rebalance && VER=$(date +%Y.%m.%d) && echo "$VER" && git tag -l "$VER" && [[ $VER > 2026.09.28 ]] && echo newer && awk -v v="###$VER###" '$0==v {f=1; next} /^###/ || /<\/CHANGES>/ {f=0} f' rebalance.plg | wc -l
  ```
  Expected: the date (e.g. `2026.10.17`), no tag line, `newer`, then `0` (the release workflow's own extraction finds no block yet — this is the failing test). Use the printed value as `VER` below. If a tag line prints or `newer` is missing: STOP, **NEEDS JUDGEMENT**.

- [ ] **Step 2: Add the block.** One edit in `rebalance.plg`, replacing `VER` in the new text with the printed value:

old:
```
<CHANGES>
###2026.09.28###
```
new:
```
<CHANGES>
###VER###
**Added**
- Data Move tab beside Array Rebalance: tick whole disks, folders or files
  in a Source tree, tick one or more receiving disks, dry-run, then start.
  Moves keep their paths, so user shares look the same afterwards, and run
  with the same progress, pause / stop / abort and log as a rebalance. The
  page keeps its Settings -> User Utilities -> Array Rebalance address, and
  Data Move uses the Array Rebalance settings.
- Placement: largest item first, onto a ticked disk that already holds the
  item's folder (the files merge), else the one with the most room. An item
  never goes back to its own disk, onto a disk ticked in full, or onto a
  disk that holds a ticked item at the same path.
- Nothing is overwritten: a same-named file on the destination, or a file
  or link where a folder is needed, fails the dry run and nothing moves.
  One that appears during the run is skipped and both copies are kept.
- Items left out (in-progress or hardlinked) and entries left behind
  (hidden ones such as .Recycle.Bin, names with a tab or line break, files
  at the disk root, excluded shares) are listed in the log, and the result
  shows as a warning.

**Fixed**
- A move stopped because a file appeared on the destination now says
  "source still present" instead of "rsync exit 0".

###2026.09.28###
```

- [ ] **Step 3: Verify.** Re-run the Step 1 `awk ... | wc -l` with the same `VER` → `23`. `RUN_SYNTAX` → `syntax ok` (the plg still parses as XML). `grep -c $'\r' rebalance.plg` → `0`. `git diff --stat` → `rebalance.plg | 24 +` only (before the commit); `grep -n 'ENTITY version' rebalance.plg` still shows `"2026.09.28"`.

- [ ] **Step 4: Commit** — `git add rebalance.plg && git commit -m "Changelog for <VER>"` (the repo's existing pattern, e.g. `76235c6 Changelog for 2026.09.28`). No tag, no push.

- [ ] **Step 5: Mutation** — `sed -i "s/^###$VER###\$/###x$VER###/" rebalance.plg`; the Step 1 `awk ... | wc -l` must print `0`; `git checkout -- rebalance.plg`; `git status --short` prints nothing.

---

### Final: review

Dispatch `reviewer` on `git diff 176022c..dev` (read closely: `$ENG` Data Move section and EXECUTE tail, `$INC/action.php`, `DataMove.page` `units()`/`plan()`; skim: `tests/engine_test.sh`, README, plg). Findings become issues or are rejected in the same session; no review report is committed. Releasing (tag from `main`) is the user's call, after the dev → main merge they make.

---

## Risks

- **Docker is not Unraid** (shfs, rsync/find/bash versions): the Checkpoint's block exercises Tasks 1-5 with the box's own bash, find, du, realpath and rsync. Tasks 6-7 are not re-verified on the box (pure arithmetic/text); a later dev install covers them.
- **#7 deferred** (Decision 9): a second start inside the first second of a run can make that run plan the newer selection. The page disables its buttons while a request is in flight; `rebalance-ctl` refuses once the pid file exists. Upgrade path if it ever bites: a per-request selection file named by `action.php`, passed via `rebalance-ctl` to the engine.
- **More warnings on whole-disk moves** (Decision 3): a disk holding `system`/`appdata` or `.Recycle.Bin` now ends "N left behind - see log". Accurate, but the user may find it noisy; revealed by the first real whole-disk run.
- **Rebalance mode has the same parent-path exposure as #4** (it checks only `-e $MNT/$dst/$rel`). Not changed here (rebalance behaviour is frozen); file it as an issue.
- **A dangling symlink above item depth is now a unit**: its live check `[[ ! -e ... ]]` reports "source no longer exists" and skips it (counted in `skipped`, run still `done`). No data loss; pre-existing behaviour for a ticked dangling link.
- **`du -l` over-counts a file hardlinked twice inside one unit** (Decision 8): could turn a tight fit into a PLAN-NOFIT. Safe direction; the log shows the size.
- **The swap set counts PLAN-SKIPped units** (Decision 1): a destination may be refused because of a unit that will not move. Ends as PLAN-NOFIT (nothing moves), never as a swap.
- **The preview's "won't fit" text** mentions only free space; when the swap rule is the cause, the dry run's PLAN-NOFIT line names it.
- **No JS test harness**: the `units()`/`plan()` mirrors are proven only by `node --check` and the Checkpoint UI step.
- **The dev install replaces the released plugin on the box** until the user reinstalls the release.

## Out of scope

- #7 (`selection.new` / per-request selection file).
- Parent-path conflict checks in rebalance mode; any other rebalance-mode change.
- Removing folders emptied by a move; a browse.php code change for non-UTF-8 names (documented only).
- Showing `warn` for a `planned` dry run (the dry-run message carries the counts; the amber state is for `done`).
- A JavaScript unit-test harness.
- Bumping `<!ENTITY version>`/`md5`, tagging, releasing, pushing (except the user-approved Checkpoint push of `dev`), merging to `main`.

## Files per task (run strictly in order; each depends on the previous commit)

| Task | Files |
| --- | --- |
| 1 | `scripts/rebalance.sh`, `DataMove.page`, `tests/engine_test.sh` |
| 2 | `scripts/rebalance.sh`, `DataMove.page`, `include/common.js`, `tests/engine_test.sh` |
| 3 | `scripts/rebalance.sh`, `include/common.js`, `tests/engine_test.sh` |
| 4 | `scripts/rebalance.sh`, `tests/engine_test.sh` |
| 5 | `scripts/rebalance.sh`, `include/action.php`, `tests/engine_test.sh` |
| Checkpoint | none (push of `dev` with user consent; box only) |
| 6 | `scripts/rebalance.sh`, `tests/engine_test.sh` |
| 7 | `scripts/rebalance.sh`, `tests/engine_test.sh`, `README.md` |
| 8 | `rebalance.plg` |

(`scripts/…`, `include/…` and `DataMove.page` are under `source/usr/local/emhttp/plugins/rebalance/`.)
