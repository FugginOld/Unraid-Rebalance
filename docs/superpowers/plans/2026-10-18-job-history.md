# Job history and a clean page after each run (branch `dev`, tip 7752aeb)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. Dispatch each Task to the `executor` agent (it pins its own model). Checkpoints are run by the main session with the owner, never by an executor.

**Goal:** after every real run (Start rebalance / Start move) the tab goes back to a clean idle page with a result banner, and the run is kept in a per-tab Job history on the flash drive (last 20 per tab), with its per-file results, move script and log.

**Architecture:** the engine's EXIT path (`on_exit`) archives a finished `run`/`move-run` into `/boot/config/plugins/rebalance/history/<start-epoch>-<mode>/`, removes the run files and rewrites the status as `state=idle` plus `last_*`. `status.php` adds `last` and `runs`; `status.php?run=`, `script.php?run=` and `log.php?run=` serve one archived run. A new `rebalance-ctl dismiss` (under the engine's flock) clears the banner, an end message or a dry run's plan. `common.js` draws the banner, the Discard button and the History pane for both tabs.

**Tech stack:** bash (engine, ctl), PHP (endpoints), vanilla JS/CSS (dashboard). No new dependency, no new file in the plugin.

**Spec:** `docs/superpowers/specs/2026-10-18-job-history-design.md` (approved; its behaviour section and the 12 numbered calls stand and are not reopened here).

**Pre-validation (2026-10-18):** Tasks 1-7 were applied to a scratch copy of 7752aeb and run in the `rebalance-test` image. Every "expect FAIL" list below is what the old code printed, every pass count is what the new code printed, every mutation `sed` changed its file and produced the named FAIL lines, `tests/syntax.sh` passed, the Task 7 smoke script printed the lines given, and the Checkpoint 1 box block printed the lines given (Docker, files mounted at the plugin path). A failure while executing therefore points at a transcription slip first.

---

## Global Constraints

- Branch `dev` only. **Never touch `main`. No push in any Task.** A push to `origin/dev` happens only at a Checkpoint, and only after the owner says yes in their own message (an agent's message is never consent). Commit after each Task. End every commit message with the attribution trailer your harness specifies.
- **LF line endings everywhere** (Unraid target; `.gitattributes`: `* text=auto eol=lf`). After editing any file run `grep -c $'\r' <file>` as its own command; it must print `0`. Any Python that writes a file uses `newline=''`.
- **TDD:** failing test, minimal code, verify. **Every new or changed engine-test assertion is mutation-tested** (each Task's last step proves it can fail).
- **Fixtures are evidence, not editable data.** `make_fixture`, the fake `df`, and every existing check stay as they are, **except the existing checks listed in Task 1 Step 1b**: those assert the old "a real run ends `done`/`error`/`stopped`/`aborted` with its files left in place" behaviour that the approved spec replaces. Each is changed exactly as written there, nowhere else. If any other existing check fails: STOP, **NEEDS JUDGEMENT**.
- **Repo verification command:** `bash tests/syntax.sh` and `bash tests/engine_test.sh` (run in Docker, see `RUN_SYNTAX` / `RUN_TESTS`).
- **Hardware is verified as we go, never in a batch.** Three stages; each ends at a Checkpoint whose box commands are posted **one block per message**, pass condition first, output filtered. The next stage does not start until the owner's pasted output is back and passes. No pasted output = the block did not run. Nothing about the box is assumed from an earlier session or a config file.
- No dry run is ever archived. Nothing writes to the flash drive during a run or per file: one archive write per finished real run.
- `rsync_argv`, the move loop, the planners and every skip/stop rule are **not touched** (spec non-goal: no change to what the engine moves, skips or stops on).
- `RB_*` environment variables are test hooks only (`RB_HIST` is new; `rebalance-ctl` now honours `RB_RUN`).
- UI: the dashboard is hosted inside the Unraid webGui shell, so its design derives from `include/common.css` (the compact style of `b5b1149`). Do **not** create or edit `.interface-design/system.md`.

### Commands used throughout

Run from Git Bash. The sandbox has no rsync, so tests run in the local Docker image `rebalance-test` (Ubuntu 24.04 + rsync, php-cli, python3, nodejs; no git inside). The repo is mounted read-only at `/src`.

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
  Prints every FAIL line, the verdict and the number of passing checks. **Baseline at 7752aeb: `all checks passed`, `121 ok`.**
- `RUN_SYNTAX` = `IN_DOCKER 'bash tests/syntax.sh' | tail -1` → pass = `syntax ok`.
- Paths, relative to the repo root `/c/Users/Joe/Documents/GitHub/Unraid-Rebalance` — set them in the shell before a mutation `sed`:
  `PLUG=source/usr/local/emhttp/plugins/rebalance; ENG=$PLUG/scripts/rebalance.sh; CTL=$PLUG/scripts/rebalance-ctl; INC=$PLUG/include`
- **Edits** are given as exact `old` → `new` text. Use the Edit tool with `old` as `old_string`. If an `old` text is not found exactly once: STOP, **NEEDS JUDGEMENT** (the file changed since this plan). No `old`/`new` text in this plan ends in a space (the Edit tool trims a trailing space; pre-validation hit this twice).
- **Test inserts** ("insert before the browse.php section"): Edit with old_string
  ```
  echo "== browse.php"
  make_fixture
  ```
  and new_string = the given block, a blank line, then those same two lines. Each Task's block therefore lands after the previous Task's block.
- **Mutation procedure** (each Task's last step): the Task is committed first. For each mutation: run the `sed` from the repo root, confirm `git diff --stat` shows `1 file changed`, run `RUN_TESTS`, confirm every listed `  FAIL  <name>` line appears (others may appear too), then `git checkout -- <file>`. Finish with `git status --short` printing nothing. If a `sed` changes nothing, or a listed FAIL does not appear: STOP, **NEEDS JUDGEMENT** (the test does not guard what it claims).

### Executor routing (who runs each step)

| Step | Runs it | Kind |
| --- | --- | --- |
| Tasks 1-8 | `executor`, unattended | transcription + check: every code text, test, command and expected output is written below |
| Checkpoints 1-3 | main session + owner | push consent, install block, one box block per message, waiting for pasted output |
| Final review | `reviewer` | judgement |

No step is left for design at execution time: the copy, layout and file format decisions are made under Decisions. The only owner judgement is which small folders to move in Checkpoints 1 and 3.

---

## Decisions made in this plan (builder's choices the spec left open)

1. **Archive layout:** `<HIST>/<started>-<mode>/` holds `meta` (key=value: `mode started ended result msg plan_count plan_kib done_count done_kib skipped`; `msg` is the engine's own end message, e.g. the summary or the `die` text), `history.tsv` (copy, only if the run got that far), `moves.sh` (from `plan.tsv` with `write_move_script <out>`, only if a plan exists) and `rebalance.log` (copy of the log). Built in `<HIST>/.tmp-<pid>` and renamed into place (`mv -T`), so a half-written run never shows in the list. `HIST=${RB_HIST:-/boot/config/plugins/rebalance/history}`.
2. **Id collision:** an id is `<start-epoch>-<mode>`, which is not unique when two runs start in the same second (the test suite does this constantly). The archive takes the next free second (`started` in `meta` stays true). The id regex is unchanged.
3. **Result** (`last_result` and `meta result`): `die` / unexpected exit → `error`; `stopped` / `aborted` → as is; `done` → `error` if any file was skipped in the move loop, or (Data Move only) `plan_skipped + plan_left > 0`, else `success`. Array Rebalance `plan_skipped` never makes an error (call 10).
4. **Banner text** is composed by the engine into `last_msg` (so the tests pin it): `Move successful - <summary>` · `Error - check the job history: <die text>` · `Finished, but some items were not moved - check the job history: <summary>` (one wording for file skips and for Data Move left out/behind) · `Stopped - see job history` (stopped and aborted, call 3). If the archive write fails: ` - history could not be saved` is appended, `last_id` is empty, and the log gets `WARNING: could not save the job history to <HIST>`.
5. **Not archived:** dry runs (`plan`, `move-plan`), and a real run that ends `done` with `plan_count == 0` ("Nothing to move" / "Nothing can be moved", calls 4-5). Everything else that reaches `on_exit` in `run`/`move-run` is archived, including a run that dies before planning (call 9). A `kill -9` (stale) is not (non-goal).
6. **After archiving:** `rm -f $RUN/{control,plan.tsv,history.tsv,start.tsv,reads.prev,moves.sh}`, then the status is rewritten from an empty `ST` as `state=idle last_mode last_result last_msg last_id` (+ `updated`). `mode`, `msg`, `warn`, `started` and the counters are gone, so the page is clean. `selection.tsv` and the log stay (the log is the "current run" log until the next start, as today).
7. **Late abort:** `on_exit` first runs `trap '' TERM INT HUP`, so a second abort while archiving cannot leave the status on the old run (anti-goal: "leaving the page stuck on the old run").
8. **Retention:** after each successful archive, folders matching `^[0-9]+-<this mode>$` beyond the newest 20 (numeric sort on the epoch) are deleted. Nothing else in the folder is touched.
9. **`status.php`:** `last` = `{result, msg, id, mode}` from the `last_*` keys, or `null`. `runs` = **`{"rebalance": [...], "move": [...]}`**, each newest first, at most 20, built from folders whose name passes `run_id_ok` and that have a `meta` with `result`; entries carry `id started ended result msg plan_count done_count done_kib skipped`. (The spec says "filtered to the requesting tab's kind", but both tabs share one poller; keying by kind lets each tab pick its own with no second request.) Kind: `-move-run` → `move`, `^[0-9]+-run` → `rebalance`.
10. **Per-file results of a past run (call 11):** `status.php?run=<id>` (no new file, so the install block's `KNOWN` list is unchanged), early-exit before any df/mdcmd work: `{ok, total, files}` with skips and failures first, then done, capped at **500** rows. A bad or unknown id → HTTP 404 `{ok:false, msg:"No such run"}`.
11. **Id validation:** `run_id_ok()` in `common.php`: `is_string` and `preg_match('/^[0-9]+-[a-z-]+\z/')` (`\z`, not `$`: `$` lets a trailing newline through). Used by `status.php`, `script.php`, `log.php`. `script.php`/`log.php` answer a bad id with HTTP 400 and the body `Bad run id`; with no `run` parameter they behave exactly as today. `log.php` now honours `RB_LOG` (tests).
12. **`rebalance-ctl dismiss`:** takes `$RUN/lock` with `flock -n` (refuses with `A rebalance is running`, exit 1, while an engine holds it), removes `{control,progress,plan.tsv,history.tsv,start.tsv,reads.prev,moves.sh}`, writes `state=idle` + `updated`, prints `Dismissed`. It never touches the history folder. `action.php` adds `dismiss` to the ctl action list (POST + webGui CSRF, like the others).
13. **UI:**
    - `own()` narrows `last` to this tab (`isMove(last.mode) === page.move`, call 12) and `runs` to this tab's list.
    - Pill on an idle page with `last`: success → `Move successful` (green), error → `Error` (red), stopped/aborted → `Stopped` (neutral). Banner = `last.msg` in the message line, same colour (new `.msg.ok` style), with a `Dismiss` link-button.
    - A `Dismiss` link-button is also shown on a dry run's `error`, and on `done`/`aborted`/`stopped` messages (dry-run end, "Nothing to move"). Not on `stale` (non-goal).
    - `planned` state: a `Discard` button after the tab's idle buttons, action `dismiss`, no confirm.
    - Meta line with no `started`: `Ready for the next job` when this tab has history, else `No run yet` (as today).
    - Data Move: while a banner is shown, the selection hints do not replace it (`renderSelection` guard gains `!o.last`).
    - History pane: a card titled **Job history** below the "Recently completed" row on both pages (`<P>-runs`, `<P>-runs-meta`). One `<details class="run">` per run: chevron, result icon (the Recently completed icons: check / cross / dash), start time, `<Result> · <done> of <planned> moved[ · N skipped]`, size moved. First open fetches `status.php?run=` and fills: the run's `msg`, links **Move script** (new tab) and **Log** (download), then the per-file rows (same row builder as Recently completed, so skips/failures show their reason). Empty: `No finished jobs yet.`; no rows: `No files were moved.`; over the cap: `+ N more - see the log`; fetch error: `Could not load this run.` The pane is rebuilt only when its id list changes, so an open entry survives the 3 s poll.
    - "Recently completed" is unchanged (call 1): after a run the polled `history` is empty, so it shows `Nothing yet.`

---

## Review Focus

The five inputs most likely to bite that the spec implies but does not spell out; each has a test in the named Task.

1. **A run id with a trailing newline, `..` or a slash in a `?run=` URL** → refused before any path is built (Task 3 `status.php?run= refuses …`, Task 5 `script.php and log.php refuse the id '<id>\n'`).
2. **Two real runs starting in the same second** → both archived, none replaced (Task 1 `a taken id is never replaced …`).
3. **Flash drive not writable** → the run still clears, keeps its result, says "history could not be saved", logs a WARNING (Task 1 `a failed archive still ends idle …`).
4. **A Data Move of thousands of items** → the expanded entry is capped at 500 rows with skips first, not a multi-MB JSON (Task 3 `status.php?run= lists skips first and caps the list at 500 lines`).
5. **Dismiss/Discard clicked while an engine is starting** → refused, nothing changed (Task 4 `dismiss refuses while the engine lock is held and changes nothing`).

Also pinned: an abort arriving while the archive is written (Task 2), a history folder holding junk or meta-less folders (Task 3).

---

# Stage 1 — engine archive, status, ctl dismiss

### Task 1: A finished real run is archived and leaves the page idle [executor]

**Files:** `$ENG`, `tests/engine_test.sh`.

**Interfaces — Produces:** status keys `state=idle last_mode last_result last_msg last_id`; archive folder `$HIST/<id>/{meta,history.tsv,moves.sh,rebalance.log}`; engine functions `archive_run <result>` (sets `LAST_ID`, returns 1 on failure), `finish_run`; `write_move_script [out]`; env `RB_HIST`. Test helpers `arch` (prints the last run's archive folder) and `meta <key>`.

- [ ] **Step 1a: Test helpers** — three edits in `tests/engine_test.sh`:

old:
```
sel() { printf '%s\n' "$@" > "$T/run/selection.tsv"; }   # Data Move: one selection.tsv line per argument
```
new:
```
sel() { printf '%s\n' "$@" > "$T/run/selection.tsv"; }   # Data Move: one selection.tsv line per argument
arch() { printf '%s' "$T/hist/$(st last_id)"; }   # the job history folder of the last finished real run
meta() { sed -n "s/^$1=//p" "$(arch)/meta" 2>/dev/null; }
```

old: `RB_LOG=$T/rb.log RB_VAR_INI=`
new: `RB_LOG=$T/rb.log RB_HIST=$T/hist RB_VAR_INI=`

- [ ] **Step 1b: Existing checks the spec changes** (the only existing checks this plan edits; each `old` is a unique fragment of one line):

1. old: `check "state is done"                        '[[ $(st state) == done ]]'`
   new: `check "a finished run leaves the page idle with a successful last run" '[[ $(st state) == idle && -z $(st msg) && -z $(st mode) && $(st last_mode) == run && $(st last_result) == success && $(st last_msg) == "Move successful - 1 of 1 moved"* ]]'`
2. old:
   ```
   check "history records the move"             'grep -q "	done	" "$T/run/history.tsv"'
   check "pid file cleaned up"                  '[[ ! -f $T/run/pid ]]'
   json=$(php "$STATUS")
   check "status.php returns valid JSON with state done" \
     'python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d[\"state\"]==\"done\" and d[\"done\"][\"count\"]==1 and len(d[\"disks\"])==4" "$json"'
   ```
   new (the whitespace inside `"	done	"` is two TAB characters, as in the old line):
   ```
   check "the archived history records the move" 'grep -q "	done	" "$(arch)/history.tsv"'
   check "the run is archived with its meta, move script and log" '[[ $(st last_id) == "$(meta started)-run" && $(meta result) == success && $(meta done_count) == 1 && $(meta plan_count) == 1 && $(grep -c "^rsync " "$(arch)/moves.sh" 2>/dev/null) == 1 && -s $(arch)/rebalance.log ]]'
   check "the run files are cleared"            '[[ ! -e $T/run/plan.tsv && ! -e $T/run/history.tsv && ! -e $T/run/start.tsv && ! -e $T/run/moves.sh ]]'
   check "pid file cleaned up"                  '[[ ! -f $T/run/pid ]]'
   json=$(php "$STATUS")
   check "status.php returns valid JSON with state idle and a clean page" \
     'python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d[\"state\"]==\"idle\" and d[\"done\"][\"count\"]==0 and d[\"plan\"][\"count\"]==0 and len(d[\"disks\"])==4" "$json"'
   ```
3. old: `check "a clash found mid-move stops the run with an error" '[[ $rc == 1 && $(st state) == error ]]'`
   new: `check "a clash found mid-move stops the run with an error" '[[ $rc == 1 && $(st state) == idle && $(st last_result) == error && $(meta result) == error ]]'`
4. old: `'[[ $(st msg) == "Move failed (source still present - did a file appear on the destination?): "* ]] && grep -q "$(printf "\tfail\tsource still present")" "$T/run/history.tsv"'`
   new: `'[[ $(meta msg) == "Move failed (source still present - did a file appear on the destination?): "* && $(st last_msg) == "Error - check the job history: Move failed (source still present"* ]] && grep -q "$(printf "\tfail\tsource still present")" "$(arch)/history.tsv"'`
5. old: `check "move-run of a folder ends done in mode move-run" '[[ $rc == 0 && $(st state) == done && $(st mode) == move-run ]]'`
   new: `check "move-run of a folder ends idle and successful, archived as a move-run" '[[ $rc == 0 && $(st state) == idle && $(st last_mode) == move-run && $(st last_result) == success && $(st last_id) == *-move-run && $(meta mode) == move-run ]]'`
6. old: `check "a single file moves to the same path" '[[ $rc == 0 && $(st state) == done &&`
   new: `check "a single file moves to the same path" '[[ $rc == 0 && $(st last_result) == success &&`
7. old: `check "an item that does not fit fails the plan with an error" '[[ $rc == 1 && $(st state) == error && $(st msg) == "1 item(s) cannot be moved"* ]]'`
   new: `check "an item that does not fit fails the plan with an error" '[[ $rc == 1 && $(st last_result) == error && $(meta msg) == "1 item(s) cannot be moved"* ]]'`
8. old: `check "a failed plan still writes the move script" '[[ -s $T/run/moves.sh ]]'`
   new: `check "a failed plan's move script is archived" '[[ -s $(arch)/moves.sh ]]'`
9. old: `'[[ $(cut -f4 "$T/run/plan.tsv") == disk2 ]]'`
   new: `'[[ $(cut -f6 "$(arch)/history.tsv") == disk2 ]]'`
10. old: `check "the item merges into the existing folder" '[[ $rc == 0 && $(st state) == done &&`
    new: `check "the item merges into the existing folder" '[[ $rc == 0 && $(st last_result) == success &&`
11. old: `check "a same-named file on the destination fails the plan" '[[ $rc == 1 && $(st state) == error ]]`
    new: `check "a same-named file on the destination fails the plan" '[[ $rc == 1 && $(st last_result) == error ]]`
12. old: `check "a folder split across two disks gathers on one" '[[ $rc == 0 && $(st state) == done && $(st done_count) == 2 &&`
    new: `check "a folder split across two disks gathers on one" '[[ $rc == 0 && $(st last_result) == success && $(meta done_count) == 2 &&`
13. old: `check "a conflict that appears after planning is skipped live" '[[ $rc == 0 && $(st state) == done && $(st done_count) == 1 && $(st skipped) == 1 ]]`
    new: `check "a conflict that appears after planning is skipped live and the run ends as an error" '[[ $rc == 0 && $(st last_result) == error && $(meta done_count) == 1 && $(meta skipped) == 1 && $(st last_msg) == "Finished, but some items were not moved - check the job history: 1 of 2 moved"* ]]`
14. old: `check "a file above Item depth in a ticked share moves" '[[ $rc == 0 && $(st state) == done &&`
    new: `check "a file above Item depth in a ticked share moves" '[[ $rc == 0 && $(st last_result) == success &&`
15. old: `'[[ $rc == 0 && $(st state) == done && $(st skipped) == 0 && -L "$T/mnt/disk3/tv/broken link"`
    new: `'[[ $rc == 0 && $(st last_result) == success && $(meta skipped) == 0 && -L "$T/mnt/disk3/tv/broken link"`
16. old: `check "a whole disk still moves its shares' items" '[[ $rc == 0 && $(st state) == done &&`
    new: `check "a whole disk still moves its shares' items" '[[ $rc == 0 && $(st state) == idle &&`
17. old: `check "a move that leaves things behind ends as a warning that says so" '[[ $(st warn) == 1 && $(st msg) == *"4 left behind"* ]]`
    new: `check "a move that leaves things behind ends as an error that says so" '[[ $(st last_result) == error && $(st last_msg) == "Finished, but some items were not moved - check the job history: "*", 4 left behind - see log" ]]`
18. old: `check "a move-run that left items out ends as a warning that counts them" '[[ $rc == 0 && $(st state) == done && $(st warn) == 1 && $(st msg) == *", 2 left out - see log" ]]`
    new: `check "a move-run that left items out ends as an error that counts them" '[[ $rc == 0 && $(st last_result) == error && $(meta msg) == *", 2 left out - see log" ]]`
19. old: `check "a link at a parent path on the destination fails the plan, nothing is written through it" '[[ $rc == 1 && $(st state) == error &&`
    new: `check "a link at a parent path on the destination fails the plan, nothing is written through it" '[[ $rc == 1 && $(st last_result) == error &&`
20. old: `check "a file that appears at a parent path is a live skip, not a failed rsync" '[[ $rc == 0 && $(st state) == done && $(st done_count) == 1 && $(st skipped) == 1 &&`
    new: `check "a file that appears at a parent path is a live skip, not a failed rsync" '[[ $rc == 0 && $(st last_result) == error && $(meta done_count) == 1 && $(meta skipped) == 1 &&`
21. old:
    ```
    for _ in $(seq 40); do [[ $(st state) == running ]] || break; sleep 0.5; done
    check "stopped after the current move"       '[[ $(st state) == stopped ]] && (( $(st done_count) - n <= 1 ))'
    ```
    new:
    ```
    for _ in $(seq 40); do [[ $(st state) == idle ]] && break; sleep 0.5; done
    check "stopped after the current move"       '[[ $(st last_result) == stopped && $(st last_msg) == "Stopped - see job history" ]] && (( $(meta done_count) - n <= 1 ))'
    ```
22. old:
    ```
    for _ in $(seq 40); do [[ $(st state) == running || $(st state) == paused ]] || break; sleep 0.5; done
    check "a stop sent right after resume is kept" '[[ $(st state) == stopped ]] && (( $(st done_count) - np <= 1 ))'
    ```
    new:
    ```
    for _ in $(seq 40); do [[ $(st state) == idle ]] && break; sleep 0.5; done
    check "a stop sent right after resume is kept" '[[ $(st last_result) == stopped ]] && (( $(meta done_count) - np <= 1 ))'
    ```
23. old:
    ```
    kill -TERM -- "-$pid" 2>/dev/null; sleep 1.5
    check "state is aborted"                     '[[ $(st state) == aborted ]]'
    ```
    new:
    ```
    kill -TERM -- "-$pid" 2>/dev/null; sleep 1.5
    for _ in $(seq 20); do [[ $(st state) == idle ]] && break; sleep 0.25; done
    check "an abort is archived and leaves the page idle" '[[ $(st state) == idle && $(st last_result) == aborted && $(meta result) == aborted && $(st last_msg) == "Stopped - see job history" ]]'
    ```

- [ ] **Step 1c: New tests** — insert before the browse.php section:

```bash
echo "== job history: dry runs and runs with nothing to move are not archived"
make_fixture
RB_HIST=$T/h-none bash "$ENGINE" plan; rc=$?
check "a dry run is not archived" '[[ $rc == 0 && $(st state) == planned && ! -e $T/h-none ]]'
sel $'item\tdisk1\tmovies/Nope' $'dest\tdisk3'
RB_HIST=$T/h-none bash "$ENGINE" move-plan; rc=$?
check "a dry run that errors is not archived and keeps its error" '[[ $rc == 1 && $(st state) == error && $(st msg) == "Bad selection"* && ! -e $T/h-none ]]'
rm -rf "$T"/mnt/disk*/*
RB_HIST=$T/h-none bash "$ENGINE" run; rc=$?
check "a run with nothing to move is not archived and keeps its message" '[[ $rc == 0 && $(st state) == done && $(st msg) == *"already balanced"* && ! -e $T/h-none ]]'

echo "== job history: a run that fails before planning is archived"
make_fixture
sed -i 's/^mdState=.*/mdState="STOPPED"/' "$T/var.ini"
bash "$ENGINE" move-run; rc=$?
check "a run on a stopped array is archived as an error" '[[ $rc == 1 && $(st state) == idle && $(st last_result) == error && $(st last_msg) == "Error - check the job history: Array is not started" && $(meta result) == error && -s $(arch)/rebalance.log && ! -e $(arch)/moves.sh ]]'

echo "== job history: an rsync failure stops the run and is archived"
make_fixture
mkdir -p "$T/fail"; printf '#!/bin/bash\nexit 23\n' > "$T/fail/rsync"; chmod +x "$T/fail/rsync"
PATH=$T/fail:$PATH bash "$ENGINE" run; rc=$?
check "an rsync failure is archived as an error with the failed file" '[[ $rc == 1 && $(st last_result) == error && $(meta msg) == "Move failed (rsync exit 23): "* ]] && grep -q "$(printf "\tfail\trsync exit 23\t")" "$(arch)/history.tsv"'

echo "== job history: a failed archive still clears the run"
make_fixture
touch "$T/hist-file"   # a file where the history folder's parent should be: no folder can be made under it, even as root
RB_HIST=$T/hist-file/history bash "$ENGINE" run; rc=$?
check "a failed archive still ends idle with the result and says history could not be saved" '[[ $rc == 0 && $(st state) == idle && $(st last_result) == success && -z $(st last_id) && $(st last_msg) == "Move successful - "*" - history could not be saved" && ! -e $T/run/plan.tsv ]] && grep -q "WARNING: could not save the job history" "$T/rb.log"'

echo "== job history: a run started in the same second as an archived run keeps both"
make_fixture
now=$EPOCHSECONDS; mkdir -p "$T/col"
for s in $(seq "$now" $(( now + 5 ))); do mkdir -p "$T/col/$s-run"; done   # every id the run can get in the next 5 s is taken
RB_HIST=$T/col bash "$ENGINE" run; rc=$?
check "a taken id is never replaced: the run gets the next free second" '[[ $rc == 0 && $(st last_id) == "$(( now + 6 ))-run" && -s $T/col/$(st last_id)/meta && $(ls "$T/col" | wc -l) == 7 && -z $(find "$T/col" -mindepth 2 ! -path "*/$(( now + 6 ))-run/*") ]]'
```

- [ ] **Step 2: Run — expect FAIL.** `RUN_TESTS` must print exactly these 30 FAIL lines, then `30 check(s) failed` and `100 ok`:
  `a finished run leaves the page idle with a successful last run` · `the archived history records the move` · `the run is archived with its meta, move script and log` · `the run files are cleared` · `status.php returns valid JSON with state idle and a clean page` · `a clash found mid-move stops the run with an error` · `the error says the source is still there, not a bare rsync exit 0` · `move-run of a folder ends idle and successful, archived as a move-run` · `a single file moves to the same path` · `an item that does not fit fails the plan with an error` · `a failed plan's move script is archived` · `a destination already holding the item folder is preferred over a roomier one` · `the item merges into the existing folder` · `a same-named file on the destination fails the plan` · `a folder split across two disks gathers on one` · `a conflict that appears after planning is skipped live and the run ends as an error` · `a file above Item depth in a ticked share moves` · `a broken link moves as a link instead of being skipped as 'no longer exists'` · `a whole disk still moves its shares' items` · `a move that leaves things behind ends as an error that says so` · `a move-run that left items out ends as an error that counts them` · `a link at a parent path on the destination fails the plan, nothing is written through it` · `a file that appears at a parent path is a live skip, not a failed rsync` · `a run on a stopped array is archived as an error` · `an rsync failure is archived as an error with the failed file` · `a failed archive still ends idle with the result and says history could not be saved` · `a taken id is never replaced: the run gets the next free second` · `stopped after the current move` · `a stop sent right after resume is kept` · `an abort is archived and leaves the page idle`
  (The three "not archived" checks pass on the old engine: they guard against regressions and are proven by mutations M4/M5.)

- [ ] **Step 3: Implement** — five edits in `$ENG`.

old:
```
LOG=${RB_LOG:-/var/log/$PLUGIN.log}
```
new:
```
LOG=${RB_LOG:-/var/log/$PLUGIN.log}
HIST=${RB_HIST:-/boot/config/plugins/$PLUGIN/history}   # job history: one folder per finished real run, on the flash drive
```

old: `write_move_script() {  # plan.tsv -> moves.sh: the dry run's moves as the exact commands, to read; nothing runs it`
new: `write_move_script() {  # [out] plan.tsv -> moves.sh (or out): the planned moves as the exact commands, to read; nothing runs it`

old:
```
  } > "$RUN/moves.sh"
}
```
new:
```
  } > "${1:-$RUN/moves.sh}"
}
```

old: `############################## MAIN ##############################`
new:
```
############################## JOB HISTORY ##############################
archive_run() {   # result -> $HIST/<started>-<mode>/ (meta, history.tsv, moves.sh, rebalance.log), built in a temp folder and renamed into place. Sets LAST_ID; returns 1 when any step fails
  local s=${ST[started]:-$EPOCHSECONDS} tmp=$HIST/.tmp-$$
  LAST_ID=""
  while [[ -e $HIST/$s-$MODE ]]; do (( s++ )); done   # a run started in the same second as an archived one: never replace it
  log "Saving the job history: $HIST/$s-$MODE"
  rm -rf "$tmp"
  if mkdir -p "$tmp" \
    && printf '%s\n' "mode=$MODE" "started=${ST[started]}" "ended=$EPOCHSECONDS" "result=$1" "msg=${ST[msg]//$'\n'/ }" \
         "plan_count=${ST[plan_count]:-0}" "plan_kib=${ST[plan_kib]:-0}" "done_count=${ST[done_count]:-0}" \
         "done_kib=${ST[done_kib]:-0}" "skipped=${ST[skipped]:-0}" > "$tmp/meta" \
    && { [[ ! -s $RUN/plan.tsv ]] || write_move_script "$tmp/moves.sh"; } \
    && { [[ ! -f $RUN/history.tsv ]] || cp "$RUN/history.tsv" "$tmp/history.tsv"; } \
    && cp "$LOG" "$tmp/rebalance.log" \
    && mv -T "$tmp" "$HIST/$s-$MODE"; then
    LAST_ID=$s-$MODE; return 0
  fi
  rm -rf "$tmp"; return 1
}
finish_run() {   # a real run is over: archive it, clear the run files, leave the page idle with last_* for the banner
  local res msg
  case $FINAL in
    error) res=error; msg="Error - check the job history: ${ST[msg]}" ;;
    stopped|aborted) res=$FINAL; msg="Stopped - see job history" ;;
    *) if (( ${ST[skipped]:-0} )) || { $MOVE && (( plan_skipped + plan_left )); }; then   # a file skipped in the move loop; for a Data Move also an item left out or behind. Array Rebalance plan_skipped is not an error
         res=error; msg="Finished, but some items were not moved - check the job history: ${ST[msg]}"
       else res=success; msg="Move successful - ${ST[msg]}"; fi ;;
  esac
  if ! archive_run "$res"; then msg+=" - history could not be saved"; log "WARNING: could not save the job history to $HIST"; fi
  rm -f "$RUN"/{control,plan.tsv,history.tsv,start.tsv,reads.prev,moves.sh}
  ST=(); st_set state idle last_mode "$MODE" last_result "$res" last_msg "$msg" last_id "$LAST_ID"
}

############################## MAIN ##############################
```

old:
```
  [[ -z $FINAL ]] && st_set state error msg "Engine stopped unexpectedly - see log"
}
```
new:
```
  [[ -z $FINAL ]] && { FINAL=error; st_set state error msg "Engine stopped unexpectedly - see log"; }
  [[ $MODE == run || $MODE == move-run ]] || return 0   # dry runs are never archived
  [[ $FINAL == done && ${plan_count:-0} == 0 ]] && return 0   # "Nothing to move": shown as today, not archived
  finish_run
}
```

- [ ] **Step 4: Run — expect PASS.** `RUN_TESTS` → `all checks passed`, `130 ok`. `RUN_SYNTAX` → `syntax ok`. `grep -c $'\r' "$ENG"` and `grep -c $'\r' tests/engine_test.sh` → `0` each.

- [ ] **Step 5: Commit** — `git add "$ENG" tests/engine_test.sh && git commit -m "Job history: archive each finished real run to the flash drive and leave the page idle with its result"`

- [ ] **Step 6: Mutations** (all on `$ENG`; each line: the `sed`, then the FAIL lines that must appear):
  - M1 `sed -i 's/res=success; msg="Move successful/res=error; msg="Move successful/' "$ENG"` → `a finished run leaves the page idle with a successful last run`, `move-run of a folder ends idle and successful, archived as a move-run`, `a failed archive still ends idle with the result and says history could not be saved`
  - M2 `sed -i 's/{ \$MOVE \&\& (( plan_skipped + plan_left )); }/(( plan_skipped ))/' "$ENG"` → `a finished run leaves the page idle with a successful last run` (call 10: Array Rebalance plan_skipped is not an error), `a move that leaves things behind ends as an error that says so`
  - M3 `sed -i 's/(( \${ST\[skipped\]:-0} )) || //' "$ENG"` → `a conflict that appears after planning is skipped live and the run ends as an error`, `a file that appears at a parent path is a live skip, not a failed rsync`
  - M4 `sed -i '/"Nothing to move": shown as today/d' "$ENG"` → `a run with nothing to move is not archived and keeps its message`
  - M5 `sed -i 's/|| return 0   # dry runs are never archived/|| true/' "$ENG"` → `a dry run is not archived`, `a dry run that errors is not archived and keeps its error`
  - M6 `sed -i '/\&\& cp "\$LOG" "\$tmp\/rebalance.log"/d' "$ENG"` → `the run is archived with its meta, move script and log`, `a run on a stopped array is archived as an error`
  - M7 `sed -i 's/write_move_script "\$tmp\/moves.sh"/write_move_script/' "$ENG"` → `the run is archived with its meta, move script and log`, `a failed plan's move script is archived`
  - M8 `sed -i '/^  rm -f "\$RUN"\/{control,plan.tsv,/d' "$ENG"` → `the run files are cleared`, `status.php returns valid JSON with state idle and a clean page`
  - M9 `sed -i 's/^  ST=(); st_set state idle/  st_set state idle/' "$ENG"` → `a finished run leaves the page idle with a successful last run`
  - M10 `sed -i 's/msg="Stopped - see job history"/msg="Stopped"/' "$ENG"` → `stopped after the current move`, `an abort is archived and leaves the page idle`
  - M11 `sed -i 's/msg="Error - check the job history: /msg="/' "$ENG"` → `the error says the source is still there, not a bare rsync exit 0`, `a run on a stopped array is archived as an error`
  - M12 `sed -i '/never replace it$/d' "$ENG"` → `a taken id is never replaced: the run gets the next free second`
  - M13 `sed -i 's/msg+=" - history could not be saved"; //' "$ENG"` → `a failed archive still ends idle with the result and says history could not be saved`
  - M14 `sed -i '/cp "\$RUN\/history.tsv" "\$tmp\/history.tsv"/d' "$ENG"` → `the archived history records the move`, `an rsync failure is archived as an error with the failed file`
  - M15 `sed -i 's/msg="Finished, but some items were not moved - check the job history: /msg="/' "$ENG"` → `a conflict that appears after planning is skipped live and the run ends as an error`, `a move that leaves things behind ends as an error that says so`

---

### Task 2: Keep the newest 20 runs per tab; a late abort cannot cut the archive short [executor]

**Files:** `$ENG`, `tests/engine_test.sh`.

**Interfaces — Consumes:** `archive_run`, `finish_run` (Task 1). **Produces:** `prune_history`.

- [ ] **Step 1: Failing tests** — insert before the browse.php section:

```bash
echo "== job history: the newest 20 runs of each kind are kept"
make_fixture
mkdir -p "$T/ret/notes"
for i in $(seq 1000 1019); do mkdir -p "$T/ret/$i-run"; echo result=success > "$T/ret/$i-run/meta"; done
for i in 1000 1001 1002; do mkdir -p "$T/ret/$i-move-run"; echo result=success > "$T/ret/$i-move-run/meta"; done
RB_HIST=$T/ret bash "$ENGINE" run; rc=$?
check "the 21st run deletes only the oldest run of its kind" '[[ $rc == 0 && $(ls "$T/ret" | grep -cxE "[0-9]+-run") == 20 && ! -e $T/ret/1000-run && -d $T/ret/1001-run && -s $T/ret/$(st last_id)/meta ]]'
check "retention leaves the other kind and other names alone" '[[ $(ls "$T/ret" | grep -cxE "[0-9]+-move-run") == 3 && -d $T/ret/notes ]]'

echo "== job history: an abort that arrives while the run is being archived is ignored"
make_fixture
REAL_CP=$(command -v cp); mkdir -p "$T/slowcp"
printf '#!/bin/bash\n[[ $* == *rebalance.log* ]] && sleep 2\nexec "%s" "$@"\n' "$REAL_CP" > "$T/slowcp/cp"; chmod +x "$T/slowcp/cp"   # copying the log into the archive takes 2 s
rm -f "$T/rb.log"   # the wait below must see this run's log line, not an earlier run's
PATH=$T/slowcp:$PATH bash "$ENGINE" run & epid=$!
for _ in $(seq 40); do grep -q "Saving the job history" "$T/rb.log" 2>/dev/null && break; sleep 0.1; done
kill -TERM "$epid" 2>/dev/null; wait "$epid"
check "a late abort neither cuts the archive short nor marks a finished run aborted" '[[ $(st state) == idle && $(st last_result) == success && -s $(arch)/rebalance.log ]]'
```

- [ ] **Step 2: Run — expect FAIL.** `RUN_TESTS` prints exactly these 2 FAIL lines, `2 check(s) failed`, `131 ok`:
  - `  FAIL  the 21st run deletes only the oldest run of its kind`
  - `  FAIL  a late abort neither cuts the archive short nor marks a finished run aborted`

- [ ] **Step 3: Implement** — three edits in `$ENG`.

old:
```
finish_run() {   # a real run is over
```
new:
```
prune_history() {   # keep the newest 20 runs of this mode
  local f n=0
  while IFS= read -r f; do
    (( ++n > 20 )) && rm -rf "${HIST:?}/$f"
  done < <(ls -1 "$HIST" | grep -xE "[0-9]+-$MODE" | sort -t- -k1,1nr)
}
finish_run() {   # a real run is over
```

old:
```
  if ! archive_run "$res"; then msg+=" - history could not be saved"; log "WARNING: could not save the job history to $HIST"; fi
```
new:
```
  if archive_run "$res"; then prune_history
  else msg+=" - history could not be saved"; log "WARNING: could not save the job history to $HIST"; fi
```

old:
```
on_exit() {
  restore_wm
```
new:
```
on_exit() {
  trap '' TERM INT HUP   # the run is ending: a late abort must not cut the archive short
  restore_wm
```

- [ ] **Step 4: Run — expect PASS.** `RUN_TESTS` → `all checks passed`, `133 ok`. `RUN_SYNTAX` → `syntax ok`. CR check on both files → `0`.

- [ ] **Step 5: Commit** — `git add "$ENG" tests/engine_test.sh && git commit -m "Job history: keep the newest 20 runs per tab; ignore an abort that arrives while the run is archived"`

- [ ] **Step 6: Mutations** (`$ENG`):
  - P1 `sed -i 's/(( ++n > 20 ))/(( ++n > 21 ))/' "$ENG"` → `the 21st run deletes only the oldest run of its kind`
  - P2 `sed -i 's/grep -xE "\[0-9\]+-\$MODE"/grep -E -- "-$MODE"/' "$ENG"` → `the 21st run deletes only the oldest run of its kind`, `retention leaves the other kind and other names alone`
  - P3 `sed -i '/^  trap .. TERM INT HUP   # the run is ending/d' "$ENG"` → `a late abort neither cuts the archive short nor marks a finished run aborted`

---

### Task 3: status.php reports the last run, lists history per tab, serves one run's results [executor]

**Files:** `$INC/common.php`, `$INC/status.php`, `tests/engine_test.sh`.

**Interfaces — Produces:** `run_id_ok($id): bool` (common.php); status JSON `last: {result,msg,id,mode}|null`, `runs: {rebalance: Run[], move: Run[]}` with `Run = {id, started, ended, result, msg, plan_count, done_count, done_kib, skipped}`; `GET status.php?run=<id>` → `{ok:true, total:int, files: Row[]}` (Row = the existing `history` row shape: `idx result reason kib src dst secs rel title`) or HTTP 404 `{ok:false, msg}`. Test helper `runq <histdir> <id> <php file>`.

- [ ] **Step 1: Failing tests** — insert before the browse.php section:

```bash
echo "== job history: status.php"
make_fixture
bash "$ENGINE" run
check "status.php reports the last run and lists it first on its tab" 'php "$STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); l=d[\"last\"]; r=d[\"runs\"][\"rebalance\"][0]; assert l[\"result\"]==\"success\" and l[\"mode\"]==\"run\" and l[\"msg\"].startswith(\"Move successful - \") and r[\"id\"]==l[\"id\"] and r[\"result\"]==\"success\" and r[\"done_count\"]==1 and r[\"plan_count\"]==1 and r[\"done_kib\"]>0 and r[\"started\"]>0, d[\"last\"]"'
bash "$ENGINE" plan
check "status.php has no last run once a new run starts" 'php "$STATUS" | python3 -c "import json,sys; assert json.load(sys.stdin)[\"last\"] is None"'
mkdir -p "$T/many/1500-run" "$T/many/1600-run" "$T/many/.tmp-1"; echo result=error > "$T/many/1500-run/meta"   # 1600-run has no meta file
for i in $(seq 1000 1021); do mkdir -p "$T/many/$i-move-run"; printf 'result=success\nstarted=%s\n' "$i" > "$T/many/$i-move-run/meta"; done
check "status.php lists at most 20 runs per tab, newest first, and only folders with a meta file" 'RB_HIST=$T/many php "$STATUS" | python3 -c "import json,sys; r=json.load(sys.stdin)[\"runs\"]; m=[x[\"id\"] for x in r[\"move\"]]; assert len(m)==20 and m[0]==\"1021-move-run\" and m[-1]==\"1002-move-run\" and [x[\"id\"] for x in r[\"rebalance\"]]==[\"1500-run\"], r"'
runq() { RB_HIST=$1 php -r '$_GET = ["run" => $argv[1]]; include $argv[2];' -- "$2" "$3"; }   # an endpoint with ?run=<id>, against history folder $1
mkdir -p "$T/many/1700-run"; echo result=error > "$T/many/1700-run/meta"
{ for i in $(seq 600); do printf '%s\tdone\t\t4\tdisk1\tdisk2\t0\t1\tm/f%s\n' "$i" "$i"; done; printf '601\tskip\tfile open\t4\tdisk1\tdisk2\t0\t1\tm/s\n'; } > "$T/many/1700-run/history.tsv"
check "status.php?run= lists skips first and caps the list at 500 lines" 'runq "$T/many" 1700-run "$STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); f=d[\"files\"]; assert d[\"ok\"] and d[\"total\"]==601 and len(f)==500 and f[0][\"result\"]==\"skip\" and f[0][\"reason\"]==\"file open\" and f[1][\"result\"]==\"done\", d[\"total\"]"'
for bad in '../many' '1700-run/..' '1700-RUN' 'x-run' '' '1800-run'; do
  check "status.php?run= refuses the id '$bad'" 'runq "$T/many" "$bad" "$STATUS" | python3 -c "import json,sys; assert json.load(sys.stdin)[\"ok\"] is False"'
done
```

- [ ] **Step 2: Run — expect FAIL.** `RUN_TESTS` prints exactly these 10 FAIL lines, `10 check(s) failed`, `133 ok`:
  `status.php reports the last run and lists it first on its tab` · `status.php has no last run once a new run starts` · `status.php lists at most 20 runs per tab, newest first, and only folders with a meta file` · `status.php?run= lists skips first and caps the list at 500 lines` · `status.php?run= refuses the id '../many'` · `… '1700-run/..'` · `… '1700-RUN'` · `… 'x-run'` · `… ''` · `… '1800-run'`

- [ ] **Step 3: Implement.** One edit in `$INC/common.php`:

old: `function csv($s) {`
new:
```
/* a job history run id, <start epoch>-<mode>: the only form ever put into a path under the history folder (\z: a trailing newline is refused) */
function run_id_ok($id) { return is_string($id) && preg_match('/^[0-9]+-[a-z-]+\z/', $id) === 1; }
function csv($s) {
```

Five edits in `$INC/status.php`:

old: `$defaultCfg = __DIR__ . '/../default.cfg';`
new:
```
$defaultCfg = __DIR__ . '/../default.cfg';
$hist       = getenv('RB_HIST') ?: "/boot/config/plugins/$plugin/history";
```

old:
```
  return $pid !== '' && ctype_digit($pid) && file_exists("/proc/$pid");
}
```
new:
```
  return $pid !== '' && ctype_digit($pid) && file_exists("/proc/$pid");
}
function hist_row($l) {   /* one history.tsv line -> one per-file result, or null */
  $f = explode("\t", $l, 9);
  if (count($f) < 9) return null;
  return ['idx' => (int)$f[0], 'result' => $f[1], 'reason' => $f[2], 'kib' => (int)$f[3], 'src' => $f[4],
          'dst' => $f[5], 'secs' => max(0, (int)$f[7] - (int)$f[6]), 'rel' => $f[8], 'title' => basename($f[8])];
}

/* ---------- ?run=<id>: one archived run's per-file results, skips and failures first, at most 500 ---------- */
if (isset($_GET['run'])) {
  $id = $_GET['run'];
  if (!run_id_ok($id) || !is_dir("$hist/$id")) { http_response_code(404); echo json_encode(['ok' => false, 'msg' => 'No such run']); exit; }
  $bad = []; $good = [];
  foreach (lines("$hist/$id/history.tsv") as $l) if ($h = hist_row($l)) { if ($h['result'] === 'done') $good[] = $h; else $bad[] = $h; }
  echo json_encode(['ok' => true, 'total' => count($bad) + count($good), 'files' => array_slice(array_merge($bad, $good), 0, 500)],
                   JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE);
  exit;
}
```

old:
```
foreach (lines("$run/history.tsv") as $l) {
  $f = explode("\t", $l, 9);
  if (count($f) < 9) continue;
  $h = ['idx' => (int)$f[0], 'result' => $f[1], 'reason' => $f[2], 'kib' => (int)$f[3], 'src' => $f[4],
        'dst' => $f[5], 'secs' => max(0, (int)$f[7] - (int)$f[6]), 'rel' => $f[8], 'title' => basename($f[8])];
  $history[] = $h;
```
new:
```
foreach (lines("$run/history.tsv") as $l) {
  if (!($h = hist_row($l))) continue;
  $history[] = $h;
```

old: `/* ---------- log tail ---------- */`
new:
```
/* ---------- job history: finished real runs on the flash drive, newest first, at most 20 per tab ---------- */
$runs = ['rebalance' => [], 'move' => []];
$ids = array_filter(@scandir($hist) ?: [], 'run_id_ok');
usort($ids, function ($a, $b) { return (int)$b <=> (int)$a; });
foreach ($ids as $id) {
  $kind = preg_match('/^[0-9]+-move-run\z/', $id) ? 'move' : (preg_match('/^[0-9]+-run\z/', $id) ? 'rebalance' : '');
  if ($kind === '' || count($runs[$kind]) >= 20) continue;
  $m = kv_file("$hist/$id/meta");
  if (!isset($m['result'])) continue;
  $runs[$kind][] = ['id' => $id, 'started' => (int)($m['started'] ?? 0), 'ended' => (int)($m['ended'] ?? 0), 'result' => $m['result'],
                    'msg' => $m['msg'] ?? '', 'plan_count' => (int)($m['plan_count'] ?? 0), 'done_count' => (int)($m['done_count'] ?? 0),
                    'done_kib' => (int)($m['done_kib'] ?? 0), 'skipped' => (int)($m['skipped'] ?? 0)];
}

/* ---------- log tail ---------- */
```

old:
```
  'warn'       => ($st['warn'] ?? '') === '1',
```
new:
```
  'warn'       => ($st['warn'] ?? '') === '1',
  'last'       => isset($st['last_result']) ? ['result' => $st['last_result'], 'msg' => $st['last_msg'] ?? '',
                                               'id' => $st['last_id'] ?? '', 'mode' => $st['last_mode'] ?? ''] : null,
  'runs'       => $runs,
```

- [ ] **Step 4: Run — expect PASS.** `RUN_TESTS` → `all checks passed`, `143 ok`. `RUN_SYNTAX` → `syntax ok`. CR check on the three files → `0`.

- [ ] **Step 5: Commit** — `git add "$INC/common.php" "$INC/status.php" tests/engine_test.sh && git commit -m "status.php: report the last run, list the job history per tab, serve one archived run's per-file results"`

- [ ] **Step 6: Mutations** (`$INC/status.php`):
  - S1 `sed -i 's/count(\$runs\[\$kind\]) >= 20/count($runs[$kind]) >= 30/' "$INC/status.php"` → `status.php lists at most 20 runs per tab, newest first, and only folders with a meta file`
  - S2 `sed -i 's/return (int)\$b <=> (int)\$a;/return (int)$a <=> (int)$b;/' "$INC/status.php"` → `status.php reports the last run and lists it first on its tab`, `status.php lists at most 20 runs per tab, …`
  - S3 `sed -i "/if (!isset(\$m\['result'\])) continue;/d" "$INC/status.php"` → `status.php lists at most 20 runs per tab, …`
  - S4 `sed -i "s/isset(\$st\['last_result'\])/isset(\$st['no_such_key'])/" "$INC/status.php"` → `status.php reports the last run and lists it first on its tab`
  - S5 `sed -i 's/if (!run_id_ok(\$id) || !is_dir/if (!is_dir/' "$INC/status.php"` → `status.php?run= refuses the id '../many'`, `… '1700-run/..'`, `… ''`
  - S6 `sed -i 's/array_merge(\$bad, \$good)/array_merge($good, $bad)/' "$INC/status.php"` → `status.php?run= lists skips first and caps the list at 500 lines`
  - S7 `sed -i 's/, 0, 500)/, 0, 600)/' "$INC/status.php"` → `status.php?run= lists skips first and caps the list at 500 lines`
  (The `\z` in `run_id_ok` is proven in Task 5, where a trailing-newline id reaches a file path.)

---

### Task 4: rebalance-ctl dismiss, and the dismiss action [executor]

**Files:** `$CTL`, `$INC/action.php`, `tests/engine_test.sh`.

**Interfaces — Produces:** `rebalance-ctl dismiss` → stdout `Dismissed`, exit 0; or `A rebalance is running`, exit 1. POST `action=dismiss` (Tasks 6-7 call it through `RB.post`).

- [ ] **Step 1: Failing tests.** Edit `tests/engine_test.sh`:

old:
```
ACTION=$PLUG/include/action.php
```
new:
```
ACTION=$PLUG/include/action.php
CTL=$PLUG/scripts/rebalance-ctl
```

old:
```
"item\tdisk1\tmovies/Movie One (2020)\nitem\tdisk2\t\ndest\tdisk3\ndest\tdisk4")" ]]'
unset RB_CTL
```
new:
```
"item\tdisk1\tmovies/Movie One (2020)\nitem\tdisk2\t\ndest\tdisk3\ndest\tdisk4")" ]]'
rm -f "$T/ctl.argv"
j=$(act action=dismiss)
check "action.php passes dismiss to rebalance-ctl" '[[ $j == *"\"ok\":true"* && $(cat "$T/ctl.argv") == dismiss ]]'
unset RB_CTL
```

Then insert before the browse.php section:

```bash
echo "== rebalance-ctl dismiss"
make_fixture
bash "$ENGINE" plan
out=$(bash "$CTL" dismiss); rc=$?
check "dismiss clears a dry run's plan and leaves an idle status with no other key" '[[ $rc == 0 && $out == Dismissed && $(cut -d= -f1 "$T/run/status" | sort | tr "\n" " ") == "state updated " && $(st state) == idle && ! -e $T/run/plan.tsv && ! -e $T/run/moves.sh && ! -e $T/run/start.tsv ]]'
bash "$ENGINE" run; id=$(st last_id)
bash "$CTL" dismiss >/dev/null
check "dismiss drops the last run's keys and keeps its archive" '[[ -n $id && -s $T/hist/$id/meta && $(cut -d= -f1 "$T/run/status" | sort | tr "\n" " ") == "state updated " ]]'
make_fixture; bash "$ENGINE" plan
( exec 9>"$T/run/lock"; flock 9; sleep 3 ) & lk=$!; sleep 0.5   # holds the engine's lock, like an engine that is starting
out=$(bash "$CTL" dismiss); rc=$?
check "dismiss refuses while the engine lock is held and changes nothing" '[[ $rc == 1 && $out == "A rebalance is running" && $(st state) == planned && -s $T/run/plan.tsv ]]'
wait "$lk"
```

- [ ] **Step 2: Run — expect FAIL.** `RUN_TESTS` prints exactly these 4 FAIL lines, `4 check(s) failed`, `143 ok`:
  `dismiss clears a dry run's plan and leaves an idle status with no other key` · `dismiss drops the last run's keys and keeps its archive` · `dismiss refuses while the engine lock is held and changes nothing` · `action.php passes dismiss to rebalance-ctl`

- [ ] **Step 3: Implement.** Four edits in `$CTL`:

old: `# rebalance-ctl plan|run|move-plan|move-run|pause|resume|stop|abort|status`
new: `# rebalance-ctl plan|run|move-plan|move-run|pause|resume|stop|abort|dismiss|status`

old:
```
#   abort   stop immediately (the item being moved is left split across two disks)
PLUGIN=rebalance
EMHTTP=/usr/local/emhttp/plugins/$PLUGIN
RUN=/var/local/$PLUGIN
```
new:
```
#   abort   stop immediately (the item being moved is left split across two disks)
#   dismiss clear a finished run's banner, an end message or a dry run's plan (refused while the engine holds its lock)
PLUGIN=rebalance
EMHTTP=/usr/local/emhttp/plugins/$PLUGIN
RUN=${RB_RUN:-/var/local/$PLUGIN}   # RB_RUN: tests only
```

old:
```
    echo "Abort sent" ;;
  status)
```
new:
```
    echo "Abort sent" ;;
  dismiss)
    exec 9>"$RUN/lock"
    flock -n 9 || { echo "A rebalance is running"; exit 1; }   # the engine holds this lock for its whole life: never race one that is starting
    rm -f "$RUN"/{control,progress,plan.tsv,history.tsv,start.tsv,reads.prev,moves.sh}
    printf 'state=idle\nupdated=%s\n' "$EPOCHSECONDS" > "$RUN/status.tmp" && mv -f "$RUN/status.tmp" "$RUN/status"
    echo "Dismissed" ;;
  status)
```

old: `    echo "usage: ${0##*/} plan|run|move-plan|move-run|pause|resume|stop|abort|status"; exit 2 ;;`
new: `    echo "usage: ${0##*/} plan|run|move-plan|move-run|pause|resume|stop|abort|dismiss|status"; exit 2 ;;`

One edit in `$INC/action.php`:

old: `'stop', 'abort'], true)) {`
new: `'stop', 'abort', 'dismiss'], true)) {`

- [ ] **Step 4: Run — expect PASS.** `RUN_TESTS` → `all checks passed`, `147 ok`. `RUN_SYNTAX` → `syntax ok`. CR check on the three files → `0`.

- [ ] **Step 5: Commit** — `git add "$CTL" "$INC/action.php" tests/engine_test.sh && git commit -m "rebalance-ctl dismiss: clear a finished run's banner or a dry run's plan, under the engine lock"`

- [ ] **Step 6: Mutations:**
  - C1 `sed -i '/flock -n 9 || { echo "A rebalance is running"; exit 1; }/d' "$CTL"` → `dismiss refuses while the engine lock is held and changes nothing`
  - C2 `sed -i "s/'abort', 'dismiss'\]/'abort']/" "$INC/action.php"` → `action.php passes dismiss to rebalance-ctl`
  - C3 `sed -i 's/rm -f "\$RUN"\/{control,progress,plan.tsv,/rm -f "$RUN"\/{control,progress,/' "$CTL"` → `dismiss clears a dry run's plan and leaves an idle status with no other key`
  - C4 `sed -i "s/printf 'state=idle/printf 'msg=x state=idle/" "$CTL"` → `dismiss clears a dry run's plan and leaves an idle status with no other key`, `dismiss drops the last run's keys and keeps its archive`

---

### Task 5: script.php and log.php serve an archived run [executor]

Belongs to stage 2 on the box (it is installed with the UI), but has no UI dependency, so it runs here with the other endpoint work. Checkpoint 1 installs it too; nothing calls it until Task 7.

**Files:** `$INC/script.php`, `$INC/log.php`, `tests/engine_test.sh`.

**Interfaces — Consumes:** `run_id_ok` (Task 3), `runq` (Task 3 test helper). **Produces:** `GET script.php?run=<id>` (inline text), `GET log.php?run=<id>` (attachment `rebalance-<id>.log`); bad id → HTTP 400, body `Bad run id`.

- [ ] **Step 1: Failing tests.** Edit `tests/engine_test.sh`:

old:
```
ACTION=$PLUG/include/action.php
```
new:
```
ACTION=$PLUG/include/action.php
LOGPHP=$PLUG/include/log.php
```

Then insert before the browse.php section:

```bash
echo "== job history: script.php and log.php serve an archived run"
make_fixture
bash "$ENGINE" run; id=$(st last_id)
check "script.php?run= serves that run's move script" '[[ -s $T/hist/$id/moves.sh && $(runq "$T/hist" "$id" "$SCRIPT") == "$(cat "$T/hist/$id/moves.sh")" ]]'
check "log.php?run= serves that run's log" '[[ -s $T/hist/$id/rebalance.log && $(runq "$T/hist" "$id" "$LOGPHP") == "$(cat "$T/hist/$id/rebalance.log")" ]]'
check "log.php without an id still serves the current log" '[[ -s $T/rb.log && $(php "$LOGPHP") == "$(cat "$T/rb.log")" ]]'
for bad in '../hist' "$id/../$id" $'\n'"$id" "$id"$'\n' ''; do
  b=${bad//$id/<id>}; b=${b//$'\n'/\\n}   # the check's name, without this run's id
  check "script.php and log.php refuse the id '$b'" '[[ $(runq "$T/hist" "$bad" "$SCRIPT") == "Bad run id" && $(runq "$T/hist" "$bad" "$LOGPHP") == "Bad run id" ]]'
done
```

- [ ] **Step 2: Run — expect FAIL.** `RUN_TESTS` prints exactly these 8 FAIL lines, `8 check(s) failed`, `147 ok`:
  `script.php?run= serves that run's move script` · `log.php?run= serves that run's log` · `log.php without an id still serves the current log` · `script.php and log.php refuse the id '../hist'` · `… '<id>/../<id>'` · `… '\n<id>'` · `… '<id>\n'` · `… ''`

- [ ] **Step 3: Implement** — replace each file's whole content with the Write tool (both are under 20 lines; the old behaviour without `?run=` is kept line for line).

`$INC/script.php`:
```php
<?php
/* Array Rebalance - show a move script, review only, never run: the dry run's, or with ?run=<id> an archived run's */
require __DIR__ . '/common.php';
$file = (getenv('RB_RUN') ?: '/var/local/rebalance') . '/moves.sh';
header('Content-Type: text/plain; charset=utf-8');
header('Content-Disposition: inline; filename="rebalance-moves.sh"');
header('X-Content-Type-Options: nosniff');
header('Cache-Control: no-store');
if (isset($_GET['run'])) {
  if (!run_id_ok($_GET['run'])) { http_response_code(400); echo "Bad run id\n"; exit; }
  $f = (getenv('RB_HIST') ?: '/boot/config/plugins/rebalance/history') . "/{$_GET['run']}/moves.sh";
  if (is_readable($f)) readfile($f); else echo "No move script for this run - it stopped before a plan was made.\n";
  exit;
}
if (is_readable($file)) readfile($file); else echo "No move script yet - run a dry run first.\n";
```

`$INC/log.php`:
```php
<?php
/* Array Rebalance - download the current run's log, or with ?run=<id> an archived run's */
require __DIR__ . '/common.php';
$logFile = getenv('RB_LOG') ?: '/var/log/rebalance.log';
$name = 'rebalance-' . date('Ymd-His') . '.log';
if (isset($_GET['run'])) {
  if (!run_id_ok($_GET['run'])) { http_response_code(400); header('Content-Type: text/plain; charset=utf-8'); echo "Bad run id\n"; exit; }
  $logFile = (getenv('RB_HIST') ?: '/boot/config/plugins/rebalance/history') . "/{$_GET['run']}/rebalance.log";
  $name = "rebalance-{$_GET['run']}.log";
}
header('Content-Type: text/plain; charset=utf-8');
header('Content-Disposition: attachment; filename="' . $name . '"');
header('Cache-Control: no-store');
if (is_readable($logFile)) readfile($logFile); else echo "No log yet.\n";
```

- [ ] **Step 4: Run — expect PASS.** `RUN_TESTS` → `all checks passed`, `155 ok`. `RUN_SYNTAX` → `syntax ok`. CR check on the three files → `0`.

- [ ] **Step 5: Commit** — `git add "$INC/script.php" "$INC/log.php" tests/engine_test.sh && git commit -m "script.php and log.php: serve an archived run's move script and log by validated id"`

- [ ] **Step 6: Mutations:**
  - L1 `sed -i 's#+.z/#+$/#' "$INC/common.php"` (turns `\z` into `$`; this exact form, because GNU sed in Git Bash mis-reads `\\z`) → `script.php and log.php refuse the id '<id>\n'`
  - L2 `sed -i "s/if (!run_id_ok(\$_GET\['run'\]))/if (false)/" "$INC/script.php"` → all five `script.php and log.php refuse the id …` lines
  - L3 `sed -i "s/if (!run_id_ok(\$_GET\['run'\]))/if (false)/" "$INC/log.php"` → all five `script.php and log.php refuse the id …` lines

---

### Checkpoint 1: STOP — owner installs Tasks 1-5 on Golem and verifies [main session + owner]

Docker passes are not Unraid passes (FAT flash, shfs, the box's bash/rsync/php). **Before posting anything:** `git status --short` prints nothing; `RUN_TESTS` → `all checks passed`, `155 ok`; `RUN_SYNTAX` → `syntax ok`. The page will still show the old UI: after a real run it reads `Idle` / `No run yet` with no banner — expected until stage 2.

**Message 1 (state-changing): push + install.**
1. Ask the owner to approve pushing `dev` to `origin/dev` (fast-forward, never `main`). Push only after a yes in the owner's own message.
2. Build the install block from the template below: fill `SHA=` with the full SHA of the pushed `dev` tip, and `FILES` with the output of
   ```bash
   cd /c/Users/Joe/Documents/GitHub/Unraid-Rebalance && SHA=$(git rev-parse dev) && git diff --name-only 1c7d3b8 "$SHA" -- source/ | while read -r p; do printf '%s  %s\n' "$(git show "$SHA:$p" | sha256sum | cut -c1-64)" "${p#source/usr/local/emhttp/plugins/rebalance/}"; done
   ```
   (`1c7d3b8` = the installed release 2026.09.28, so every file changed since it is re-verified. `KNOWN` is unchanged: this plan adds no file.)
3. Pre-test the block locally against a fake plugin dir and the live raw URLs (idle, busy, tampered hash), as on 2026-10-17. Then post it as the only block in the message.

Template (as used on 2026-10-17):
```bash
SHA=<full sha of the pushed dev tip>
BASE=${BASE:-https://raw.githubusercontent.com/FugginOld/Unraid-Rebalance/$SHA/source/usr/local/emhttp/plugins/rebalance}
PLUG=${PLUG:-/usr/local/emhttp/plugins/rebalance}
CTL=${CTL:-$PLUG/scripts/rebalance-ctl}
FILES='
<sha256>  <path>      (one line per file from the command in step 2)
'
KNOWN='
DataMove.page
README.md
Rebalance.page
RebalanceMain.page
default.cfg
include/action.php
include/browse.php
include/common.css
include/common.js
include/common.php
include/log.php
include/script.php
include/status.php
scripts/rebalance-ctl
scripts/rebalance.sh
'
[ "$("$CTL" status)" = idle ] || { echo "NOT IDLE - nothing installed"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
echo "$FILES" | while read -r h f; do [ -n "$f" ] || continue
  mkdir -p "$T/$(dirname "$f")"
  curl -fsSL "$BASE/$f" -o "$T/$f" || { echo "DOWNLOAD FAILED: $f"; exit 1; }
done || exit 1
echo "$FILES" | while read -r h f; do [ -n "$f" ] || continue
  [ "$(sha256sum "$T/$f" | cut -c1-64)" = "$h" ] || { echo "HASH MISMATCH: $f - nothing installed"; exit 1; }
done || exit 1
B=/tmp/rebalance-backup-$(date +%s); cp -a "$PLUG" "$B" && echo "backup: $B"
echo "$FILES" | while read -r h f; do [ -n "$f" ] || continue
  case $f in scripts/*) m=755;; *) m=644;; esac
  install -D -m $m "$T/$f" "$PLUG/$f"
  [ "$(sha256sum "$PLUG/$f" | cut -c1-64)" = "$h" ] && echo "$f: OK" || echo "$f: VERIFY FAILED"
done
(cd "$PLUG" && find . -type f | sed 's#^\./##' | while read -r f; do echo "$KNOWN" | grep -qxF "$f" || echo "EXTRA (not in repo): $f"; done)
```

Pass: a `backup:` line, one `<file>: OK` line per listed file (`scripts/rebalance.sh`, `scripts/rebalance-ctl`, `include/status.php`, `include/common.php`, `include/script.php`, `include/log.php`, `include/action.php` are among them), and no `NOT IDLE`, `DOWNLOAD FAILED`, `HASH MISMATCH`, `VERIFY FAILED` or `EXTRA` line.

**Message 2 (read-only on the array; writes only a scratch folder on the flash):** the installed engine against a scratch fake array under `/tmp`, with the history in a scratch folder next to the real one on `/boot` (tests FAT: rename of a folder, retention), then `status.php` and `rebalance-ctl dismiss` on the scratch run dir. It does not touch `/mnt`, `/var/local/rebalance`, `/var/log/rebalance.log`, the real history or the md driver, and removes both scratch folders. It runs in a subshell. Pre-test it first exactly as pre-validated:
`MSYS_NO_PATHCONV=1 docker run --rm -v "C:/Users/Joe/Documents/GitHub/Unraid-Rebalance/source/usr/local/emhttp/plugins/rebalance:/usr/local/emhttp/plugins/rebalance:ro" -v "<folder holding the block as box1.sh>:/s:ro" rebalance-test bash -c 'mkdir -p /boot/config/plugins/rebalance; bash /s/box1.sh'`

```bash
( P=/usr/local/emhttp/plugins/rebalance; E=$P/scripts/rebalance.sh; C=$P/scripts/rebalance-ctl; S=$P/include/status.php
T=$(mktemp -d /tmp/rb-verify.XXXXXX); M=$T/mnt; H=/boot/config/plugins/rebalance/history-verify.$$
mkdir -p "$T/bin" "$T/run" "$T/cfg/shares" "$M/disk1" "$M/disk2" "$M/disk3"
cat > "$T/bin/df" <<'DF'
#!/bin/bash
for a in "$@"; do case $a in --output=*) f=${a#--output=};; -*) ;; *) p=$a;; esac; done
u=$(du -sk "$p" | cut -f1); echo hdr
if [ "$f" = avail ]; then echo $((100000-u)); else echo "100000 $u $((100000-u))"; fi
DF
chmod +x "$T/bin/df"
printf 'MIN_FREE_GB="0"\nTURBO_WRITE="false"\nPAUSE_ON_PARITY="false"\nNOTIFY="false"\nSKIP_RECENT_MIN="0"\nSKIP_OPEN_FILES="false"\n' > "$T/rb.cfg"
printf 'mdState="STARTED"\nmdResyncPos="0"\n' > "$T/var.ini"
export PATH=$T/bin:$PATH RB_MNT=$M RB_RUN=$T/run RB_LOG=$T/rb.log RB_HIST=$H RB_VAR_INI=$T/var.ini RB_SHARE_CFG=$T/cfg RB_CFG=$T/rb.cfg RB_NOTIFY_BIN=/bin/true
f() { mkdir -p "$(dirname "$M/$1")"; head -c 4096 /dev/urandom > "$M/$1"; }
k() { sed -n "s/^$1=//p" "$T/run/status"; }
r() { printf '%s\n' "${@:3}" > "$T/run/selection.tsv"; bash "$E" "$2" >/dev/null 2>&1; rc=$?
  echo "$1 rc=$rc state=$(k state) result=$(k last_result) archives=$(ls "$H" 2>/dev/null | wc -l) | $(k last_msg | cut -c1-60)"; }
f disk1/tv/A/a; f disk1/tv/B/b; f disk3/tv/B/b
r 1 move-run $'item\tdisk1\ttv/A' $'dest\tdisk2'
echo "1 files: $(ls "$H/$(k last_id)" | tr '\n' ' ')"
r 2 move-plan $'item\tdisk1\ttv/B' $'dest\tdisk2'
r 3 move-run $'item\tdisk1\ttv/B' $'dest\tdisk3'
r 4 move-run $'item\tdisk1\tnope' $'dest\tdisk2'
for i in $(seq 1000 1019); do mkdir -p "$H/$i-move-run"; echo result=success > "$H/$i-move-run/meta"; done
f disk1/tv/C/c; r 5 move-run $'item\tdisk1\ttv/C' $'dest\tdisk2'
echo "5 oldest kept: $(ls "$H" | grep -xE '[0-9]+-move-run' | sort -n | head -1)"
php "$S" | php -r '$d = json_decode(stream_get_contents(STDIN), true); echo "6 status: ", $d["state"], " ", $d["last"]["result"], " runs=", count($d["runs"]["move"]), "\n";'
echo "7 $("$C" dismiss): $(cut -d= -f1 "$T/run/status" | tr '\n' ' ')"
rm -rf "$T" "$H"; echo "8 left behind: $(ls -d "$T" "$H" 2>/dev/null | wc -l)" )
```

Pass — exactly these 9 lines, ignoring trailing spaces; the size in parentheses may differ, everything else must match:
```
1 rc=0 state=idle result=success archives=1 | Move successful - 1 of 1 moved (... KiB), 0 skipped
1 files: history.tsv meta moves.sh rebalance.log
2 rc=0 state=planned result= archives=1 |
3 rc=1 state=idle result=error archives=2 | Error - check the job history: 1 item(s) cannot be moved - t
4 rc=1 state=idle result=error archives=3 | Error - check the job history: Bad selection: /tmp/rb-verify
5 rc=0 state=idle result=success archives=20 | Move successful - 1 of 1 moved (... KiB), 0 skipped
5 oldest kept: 1004-move-run
6 status: idle success runs=20
7 Dismissed: state updated
8 left behind: 0
```
The old engine prints `state=done` on line 1 and `usage:` on line 7: either means the install did not take. Any other difference: STOP, **NEEDS JUDGEMENT** — ask for the scratch log by re-running with `rm -rf "$T" "$H"` replaced by `tail -30 "$T/rb.log"; rm -rf "$T" "$H"`.

**Message 3 (state-changing on the array — the owner's own small real Data Move, spec Verification step 1):** in the browser, **Data Move** tab: tick one small folder (a few MB) and one destination disk, **Dry run**, then **Start move**; wait for the page to read `Idle`. Then post this read-only block:

```bash
R=/var/local/rebalance; H=/boot/config/plugins/rebalance/history; id=$(sed -n 's/^last_id=//p' $R/status); grep -v '^updated=' $R/status | sort; echo "files: $(ls "$H/$id" | tr '\n' ' ')"; grep -E '^(mode|result|done_count|skipped)=' "$H/$id/meta" | tr '\n' ' '; echo; echo "run dir: $(ls $R | tr '\n' ' ')"; echo "archives: $(ls $H | wc -l)"
```
Pass: `last_id=<digits>-move-run`, `last_mode=move-run`, `last_msg=Move successful - N of N moved (...), 0 skipped`, `last_result=success`, `state=idle` (no other key); `files: history.tsv meta moves.sh rebalance.log`; `mode=move-run result=success done_count=N skipped=0`; the run dir lists none of `plan.tsv history.tsv start.tsv moves.sh`; `archives: 1`. Do not dismiss: Checkpoint 2 uses this banner.

**Stage 2 starts only after Messages 1-3 pass.**

---

# Stage 2 — endpoints in the UI: banner, Discard, History pane

### Task 6: Banner, pill, Dismiss and Discard [executor]

**Files:** `$INC/common.js`, `$INC/common.css`, `$PLUG/DataMove.page`.

**Interfaces — Consumes:** status `last`, `runs` (Task 3); POST `dismiss` (Task 4). **Produces:** `own()` output carries `last` (this tab's or `null`) and `runs` (this tab's array); constants `LAST`, `RESULT`; `dismissBtn()`.

There is no JavaScript test harness: this Task is verified by `RUN_SYNTAX`, the unchanged `RUN_TESTS` count, the Task 7 smoke script and Checkpoint 2.

- [ ] **Step 1: Implement** — six edits in `$INC/common.js`:

old:
```
    error: ['Error', 'bad'], stale: ['Engine not running', 'bad']
  };
```
new:
```
    error: ['Error', 'bad'], stale: ['Engine not running', 'bad']
  };
  var LAST = { success: ['Move successful', 'ok'], error: ['Error', 'bad'], stopped: ['Stopped', ''], aborted: ['Stopped', ''] };   // the idle page after a real run: pill and banner, by status.php last.result
  var RESULT = { success: 'Successful', error: 'Error', stopped: 'Stopped', aborted: 'Aborted' };   // a job history entry
```

old:
```
    function own(d) {   // a run of the other tab's kind shows here as idle; d.other holds its state while it is active
      if (!d.mode || isMove(d.mode) === !!page.move) return d;
```
new:
```
    function own(d) {   // a run of the other tab's kind shows here as idle; d.other holds its state while it is active. last and runs: this tab's kind only
      d = Object.assign({}, d, { last: d.last && isMove(d.last.mode) === !!page.move ? d.last : null, runs: (d.runs || {})[page.move ? 'move' : 'rebalance'] || [] });
      if (!d.mode || isMove(d.mode) === !!page.move) return d;
```

old:
```
      b.addEventListener('click', function () { act(action); }); return b;
    }
```
new:
```
      b.addEventListener('click', function () { act(action); }); return b;
    }
    function dismissBtn() {   // in the message line: clears the banner or an end message (rebalance-ctl dismiss)
      var b = el('button', 'lnk', 'Dismiss'); b.type = 'button';
      b.addEventListener('click', function () { act('dismiss'); }); return b;
    }
```

old: `      var s = STATES[d.state] || [d.state, ''];`
new: `      var s = d.state === 'idle' && d.last ? LAST[d.last.result] || STATES.idle : STATES[d.state] || [d.state, ''];`

old: `      } else meta.push('No run yet');`
new: `      } else meta.push(d.runs.length ? 'Ready for the next job' : 'No run yet');`

old:
```
        page.idle(d).forEach(function (b) { a.append(button(b[0], b[1], b[2], b[3] || !!d.other)); });
      }
      if (d.other) setMsg(page.otherBusy, 'warn', otherLink());
      else if (d.state === 'error' || d.state === 'stale') setMsg(d.msg || 'The engine stopped unexpectedly - check the log.', 'bad');
      else setMsg(d.msg || '', warn ? 'warn' : '');
```
new:
```
        page.idle(d).forEach(function (b) { a.append(button(b[0], b[1], b[2], b[3] || !!d.other)); });
        if (d.state === 'planned') a.append(button('Discard', 'dismiss', '', !!d.other));   // drops the dry run's plan and script
      }
      if (d.other) setMsg(page.otherBusy, 'warn', otherLink());
      else if (d.state === 'idle' && d.last) setMsg(d.last.msg, (LAST[d.last.result] || STATES.idle)[1], dismissBtn());
      else if (d.state === 'error' || d.state === 'stale') setMsg(d.msg || 'The engine stopped unexpectedly - check the log.', 'bad', d.state === 'error' ? dismissBtn() : null);
      else setMsg(d.msg || '', warn ? 'warn' : '', d.msg && ['done', 'aborted', 'stopped'].indexOf(d.state) >= 0 ? dismissBtn() : null);   // a dry run's end or "Nothing to move": stays until dismissed
```

One edit in `$INC/common.css`:

old:
```
.rb .list .empty{color:var(--muted);padding:6px 0;border-top:1px solid var(--line)}
```
new:
```
.rb .list .empty{color:var(--muted);padding:6px 0;border-top:1px solid var(--line)}
.rb .msg.ok{border-color:var(--green);color:var(--green-t)}
```

One edit in `$PLUG/DataMove.page`:

old: `    if (!o.other && o.state !== 'error' && o.state !== 'stale') {`
new: `    if (!o.other && !o.last && o.state !== 'error' && o.state !== 'stale') {   // a finished run's banner stays until dismissed`

- [ ] **Step 2: Verify.** `RUN_SYNTAX` → `syntax ok`. `RUN_TESTS` → `all checks passed`, `155 ok`. CR check on the three files → `0`.

- [ ] **Step 3: Commit** — `git add "$INC/common.js" "$INC/common.css" "$PLUG/DataMove.page" && git commit -m "Dashboard: a finished run's result banner with Dismiss on its own tab; Discard a dry run's plan"`

---

### Task 7: Job history pane on both tabs [executor]

**Files:** `$INC/common.js`, `$INC/common.css`, `$PLUG/RebalanceMain.page`, `$PLUG/DataMove.page`.

**Interfaces — Consumes:** `own()` `runs` (Task 6), `status.php?run=` (Task 3), `script.php?run=` / `log.php?run=` (Task 5). **Produces:** `histItem(x)` (one per-file row, shared by Recently completed and the pane), `renderRuns(d)`; element ids `<P>-runs`, `<P>-runs-meta` (`P` = `rb` / `dm`).

The markup and the JS land in one commit: `renderRuns` writes to `<P>-runs`, which must exist on both pages.

- [ ] **Step 1: Implement** — three edits in `$INC/common.js`:

old:
```
      d.history.forEach(function (x) {
        var it = el('div', 'item'), l = el('div'); l.style.cssText = 'display:flex;align-items:center;gap:10px;min-width:0';
```
new:
```
      d.history.forEach(function (x) { h.append(histItem(x)); });
    }
    function histItem(x) {   // one per-file result: the live Recently completed list and an expanded job history entry
        var it = el('div', 'item'), l = el('div'); l.style.cssText = 'display:flex;align-items:center;gap:10px;min-width:0';
```

old:
```
        it.append(l, s); h.append(it);
      });
    }
```
new:
```
        it.append(l, s); return it;
    }

    var runsKey = null;   // the pane is rebuilt only when its list changes, so an expanded entry stays open between polls
    function renderRuns(d) {
      var key = d.runs.map(function (r) { return r.id; }).join(' ');
      if (key === runsKey) return;
      runsKey = key;
      $('runs-meta').textContent = d.runs.length ? 'last ' + d.runs.length + (d.runs.length === 1 ? ' run' : ' runs') : '';
      var box = $('runs'); box.textContent = '';
      if (!d.runs.length) { box.append(el('div', 'empty', 'No finished jobs yet.')); return; }
      d.runs.forEach(function (r) {
        var det = el('details', 'run'), sum = el('summary'), l = el('div'), txt = el('div'), body = el('div', 'body');
        l.style.cssText = 'display:flex;align-items:center;gap:10px;min-width:0'; txt.style.minWidth = '0';
        var icon = r.result === 'success' ? svg('M3 8.5l3.2 3L13 4.5', 'var(--green)') : r.result === 'error' ? svg('M4 4l8 8M12 4l-8 8', 'var(--red-t)') : svg('M4 8h8', 'var(--amber-t)');
        txt.append(el('div', 't', fmtTime(r.started)), el('div', 'r', (RESULT[r.result] || r.result) + ' \u00b7 ' + r.done_count + ' of ' + r.plan_count + ' moved' + (r.skipped ? ' \u00b7 ' + r.skipped + ' skipped' : '')));
        l.append(svg('M6 4l4 4-4 4', 'var(--muted)'), icon, txt);
        var sz = el('div', 'mono soft', fmtKiB(r.done_kib)); sz.style.cssText = 'font-size:12px;white-space:nowrap';
        sum.append(l, sz); det.append(sum, body);
        det.addEventListener('toggle', function () {
          if (!det.open || body.childNodes.length) return;   // filled once, on the first open
          var q = '?run=' + encodeURIComponent(r.id), links = el('div', 'links'), list = el('div', 'list');
          var sc = el('a', null, 'Move script'); sc.href = BASE + 'script.php' + q; sc.target = '_blank'; sc.rel = 'noopener';
          var lg = el('a', null, 'Log'); lg.href = BASE + 'log.php' + q;
          links.append(sc, lg); list.append(el('div', 'empty', 'Loading\u2026'));
          body.append(el('div', 'r', r.msg), links, list);
          fetch(BASE + 'status.php' + q, { cache: 'no-store' }).then(function (x) { return x.json(); })
            .then(function (j) {
              if (!j.ok) throw j;
              list.textContent = '';
              if (!j.files.length) list.append(el('div', 'empty', 'No files were moved.'));
              j.files.forEach(function (x) { list.append(histItem(x)); });
              if (j.total > j.files.length) list.append(el('div', 'empty', '+ ' + (j.total - j.files.length) + ' more - see the log'));
            })
            .catch(function () { list.textContent = ''; list.append(el('div', 'empty', 'Could not load this run.')); });
        });
        box.append(det);
      });
    }
```
(The six body lines of `histItem` between these two edits are unchanged; they keep their current indentation.)

old: `renderLists(o); renderLog(o);`
new: `renderLists(o); renderRuns(o); renderLog(o);`

One edit in `$INC/common.css`:

old:
```
.rb .msg.ok{border-color:var(--green);color:var(--green-t)}
```
new:
```
.rb .msg.ok{border-color:var(--green);color:var(--green-t)}
.rb details.run{background:none;border:0;border-top:1px solid var(--line);border-radius:0;padding:0}
.rb details.run>summary{display:flex;justify-content:space-between;align-items:center;gap:12px;padding:6px 0;font:500 14px var(--sans);list-style:none}
.rb details.run>summary::-webkit-details-marker{display:none}
.rb details.run>summary .t{font-size:14px;font-weight:500}
.rb details.run>summary .r,.rb details.run .body>.r{font-family:var(--mono);font-size:12px;color:var(--muted)}
.rb details.run>summary>div:first-child>.ico:first-child{transition:transform .15s} .rb details.run[open]>summary>div:first-child>.ico:first-child{transform:rotate(90deg)}
.rb details.run .body{display:flex;flex-direction:column;gap:6px;padding:0 0 8px 26px}
.rb details.run .links{display:flex;gap:16px;font-size:13px}
```

One edit in `$PLUG/RebalanceMain.page`:

old:
```
        <div class="list" id="rb-hist"></div>
      </section>
    </div>
  </div>
```
new:
```
        <div class="list" id="rb-hist"></div>
      </section>
    </div>
  </div>

  <section class="card">
    <div class="cardhead"><h2 class="h2">Job history</h2><span class="muted" id="rb-runs-meta" style="font-size:13px"></span></div>
    <div class="list" id="rb-runs"></div>
  </section>
```

One edit in `$PLUG/DataMove.page`:

old:
```
      <div class="list" id="dm-hist"></div>
    </section>
  </div>
```
new:
```
      <div class="list" id="dm-hist"></div>
    </section>
  </div>

  <section class="card">
    <div class="cardhead"><h2 class="h2">Job history</h2><span class="muted" id="dm-runs-meta" style="font-size:13px"></span></div>
    <div class="list" id="dm-runs"></div>
  </section>
```

- [ ] **Step 2: Verify.** `RUN_SYNTAX` → `syntax ok`. `RUN_TESTS` → `all checks passed`, `155 ok`. CR check on the four files → `0`. `common.js` must stay ASCII (it writes `·` and `…` as six-character escapes, like the rest of the file; the Edit tool turned them into raw characters during pre-validation): `LC_ALL=C.UTF-8 grep -cP '[^\x00-\x7F]' "$INC/common.js"` → `0`. If it prints more, run `sed -i 's/\xc2\xb7/\\u00b7/g; s/\xe2\x80\xa6/\\u2026/g' "$INC/common.js"` and check again.

- [ ] **Step 3: Smoke (not committed).** Write this file to the session scratchpad as `smoke.js` (it renders both tabs' shared code against a stub DOM with a post-run status in which the last run is a Data Move):

```js
// smoke: render both tabs' common code against a stub DOM with a post-run status; throws on any runtime error
function E(tag){ var e={tag:tag,children:[],childNodes:null,style:{},dataset:{},listeners:{},attrs:{},_t:'',className:'',hidden:false,open:false,
  append:function(){for(var i=0;i<arguments.length;i++){var c=arguments[i]; this.children.push(typeof c==='string'?{text:c}:c);} this.childNodes=this.children;},
  appendChild:function(c){this.append(c);}, setAttribute:function(k,v){this.attrs[k]=v;}, addEventListener:function(k,f){(this.listeners[k]=this.listeners[k]||[]).push(f);},
  focus:function(){}, scrollIntoView:function(){}, get lastChild(){return this.children[this.children.length-1]||E('span');},
  get textContent(){return this._t+this.children.map(function(c){return c.text||c.textContent||'';}).join('');}, set textContent(v){this._t=v;this.children=[];this.childNodes=this.children;}};
  e.childNodes=e.children; return e; }
var ids={}; global.document={hidden:false,getElementById:function(id){return ids[id]||(ids[id]=E('div'));},createElement:E,createElementNS:function(n,t){return E(t);},addEventListener:function(){},querySelectorAll:function(){return [];},activeElement:null};
global.window={}; global.setInterval=function(){}; global.URLSearchParams=function(){};
var status={now:2000,state:'idle',mode:null,msg:'',warn:false,request:'',pause_reason:'',started:null,updated:1999,turbo:'off',target_pct:30,tol_pct:1,
  plan:{count:0,kib:0,left_out:0},done:{count:0,kib:0,skipped:0,failed:0},current:null,queue:[],queue_count:0,queue_kib:0,history:[],disks:[{name:'disk1',size:100,used:50,avail:50,start_used:null,excluded:false}],
  array:{state:'STARTED',parity:false,mover:false,docker:false,write_method:'1',observed:null},cfg:{SKIP_OPEN_FILES:'true'},log:[],
  last:{result:'success',msg:'Move successful - 1 of 1 moved',id:'1000-move-run',mode:'move-run'},
  runs:{rebalance:[],move:[{id:'1000-move-run',started:1000,ended:1001,result:'success',msg:'1 of 1 moved',plan_count:1,done_count:1,done_kib:4,skipped:0}]}};
global.fetch=function(u){ return Promise.resolve({ok:true,json:function(){return Promise.resolve(/run=/.test(u)?{ok:true,total:1,files:[{idx:1,result:'skip',reason:'file open',kib:4,src:'disk1',dst:'disk2',secs:0,rel:'a/b',title:'b'}]}:status);},text:function(){return Promise.resolve('');}}); };
eval(require('fs').readFileSync(process.argv[2],'utf8'));
var RB=window.RB;
['rb','dm'].forEach(function(P){ RB.dashboard(P,{csrf:'',move:P==='dm',otherName:'x',otherTab:'t',otherRoot:'r',otherBusy:'busy',idle:function(){return [['Dry run','plan']];},render:function(){}}); });
setTimeout(function(){
  console.log('rb msg:', JSON.stringify(ids['rb-msg'].textContent), 'cls:', ids['rb-msg'].className, '| pill:', ids['rb-pill'].className);
  console.log('dm msg:', JSON.stringify(ids['dm-msg'].textContent), 'cls:', ids['dm-msg'].className, '| pill:', ids['dm-pill'].className, '| meta:', ids['dm-meta'].textContent);
  console.log('dm runs:', ids['dm-runs'].children.length, ids['dm-runs-meta'].textContent, '| rb runs:', ids['rb-runs'].textContent);
  var det=ids['dm-runs'].children[0]; det.open=true; det.listeners.toggle[0]();
  setTimeout(function(){ console.log('expanded body items:', det.children[1].children.map(function(c){return c.className;}).join(','), '| list:', det.children[1].children[2].children.length); },50);
},50);
```
Run: `MSYS_NO_PATHCONV=1 docker run --rm -v "<scratchpad>:/s:ro" -v "C:/Users/Joe/Documents/GitHub/Unraid-Rebalance:/src:ro" rebalance-test node /s/smoke.js /src/source/usr/local/emhttp/plugins/rebalance/include/common.js`
Pass — exactly (call 12: the banner only on the Data Move tab):
```
rb msg: "" cls: msg | pill: pill
dm msg: "Move successful - 1 of 1 moved Dismiss" cls: msg ok | pill: pill ok | meta: Ready for the next job
dm runs: 1 last 1 run | rb runs: No finished jobs yet.
expanded body items: r,links,list | list: 1
```
(`pill: pill` may carry a trailing space.) A thrown error or any other line: STOP, **NEEDS JUDGEMENT**.

- [ ] **Step 4: Commit** — `git add "$INC/common.js" "$INC/common.css" "$PLUG/RebalanceMain.page" "$PLUG/DataMove.page" && git commit -m "Dashboard: Job history pane on both tabs, each run expandable to its per-file results, move script and log"`

---

### Checkpoint 2: STOP — owner installs Tasks 6-7 and checks the UI [main session + owner]

**Before posting:** `git status --short` empty; `RUN_TESTS` → `155 ok`; `RUN_SYNTAX` → `syntax ok`.

**Message 1 (state-changing): push + install** — same procedure and template as Checkpoint 1 Message 1 (owner's yes for the push, new `SHA=`, regenerated `FILES`, local pre-test). Pass: as there, and `include/common.js`, `include/common.css`, `RebalanceMain.page`, `DataMove.page` are among the `OK` lines.

**Message 2 (UI, no command; then one read-only block).** Hard-refresh **Settings → User Utilities → Array Rebalance**. Pass, in order:
1. **Data Move** tab: pill `Move successful` (green); green banner `Move successful - N of N moved (...), 0 skipped` with a `Dismiss` link; meta `Ready for the next job`; Recently completed `Nothing yet.`; no "View move script" pill. **Job history** card lists one entry: start time, `Successful · N of N moved`, size.
2. Expand the entry: the run's message, **Move script** (opens the script in a new tab, `rsync` lines visible), **Log** (downloads `rebalance-<id>.log`), then the moved item(s), each with a check icon.
3. **Array Rebalance** tab: pill `Idle`, no banner, Job history `No finished jobs yet.` (call 12).
4. Data Move tab: click **Dismiss** → banner gone, pill `Idle`, the history entry stays.
5. Array Rebalance tab: **Dry run** → `Dry run ready` with a **Discard** button → click **Discard** → plan line, "View move script" pill and the Move script panel are gone, pill `Idle`. (A dry run only scans; nothing moves.)
6. The browser console shows no errors on either tab; the page is usable at phone width (the pane's rows wrap like Recently completed).

Then post this block (read-only):
```bash
R=/var/local/rebalance; sed 's/^updated=.*/updated=N/' $R/status | sort | tr '\n' ' '; echo; ls $R | tr '\n' ' '; echo
```
Pass: line 1 is `state=idle updated=N`; line 2 lists none of `plan.tsv moves.sh start.tsv history.tsv`.

Any step failing: STOP, **NEEDS JUDGEMENT** (screenshot or console text from the owner).

---

# Stage 3 — the error path on the box

### Checkpoint 3: forced skip on real data [main session + owner]

**Message 1 (state-changing: one file's mtime on the owner's data).** In the browser, **Data Move** tab: tick two small folders `A` and `B` on the same disk and one destination disk, then **Dry run**; both must show in Up next. Then post this block with `B` filled in by the owner (the folder ticked as `B`):
```bash
B='/mnt/diskN/<share>/<folder B>'; grep -h '^SKIP_RECENT_MIN' /usr/local/emhttp/plugins/rebalance/default.cfg /boot/config/plugins/rebalance/rebalance.cfg 2>/dev/null | tail -1; f=$(find "$B" -type f | head -1); touch "$f" && echo "touched: $f"
```
Pass: `SKIP_RECENT_MIN="<n>"` with n ≥ 1, and one `touched:` line. (n = 0 disables the check: STOP, the owner sets it ≥ 1 in Settings first.) Then, within n minutes, click **Start move** and wait for the page to go idle.

UI pass: pill `Error` (red); red banner `Finished, but some items were not moved - check the job history: 1 of 2 moved (...), 1 skipped` with `Dismiss`; the newest Job history entry shows a red cross and `Error · 1 of 2 moved · 1 skipped`; expanded, its first row is `B` with `· modified <nm ago` and `skipped`, then `A` with a check.

**Message 2 (read-only):**
```bash
R=/var/local/rebalance; H=/boot/config/plugins/rebalance/history; id=$(sed -n 's/^last_id=//p' $R/status); sed -n 's/^last_\(result\|msg\)=//p' $R/status; grep -E '^(result|done_count|skipped)=' "$H/$id/meta" | tr '\n' ' '; echo; cut -f2,3,9 "$H/$id/history.tsv"; echo "move archives: $(ls $H | grep -c -- '-move-run$')"
```
Pass: the two `last_` values are `error` and the banner text above (either order); `result=error done_count=1 skipped=1`; one `skip<TAB>modified <nm ago<TAB><B's path>` line and one `done<TAB><TAB><A's path>` line; `move archives: 2`. Any difference: STOP, **NEEDS JUDGEMENT**. The owner may then Dismiss.

---

### Task 8: README — job history, Dismiss and Discard [executor]

**Files:** `README.md`.

- [ ] **Step 1: Edit** — three edits:

old: `**Controls:** *Pause* and *Stop* take effect after the current move finishes. *Abort* stops immediately — the item in flight is left split across two disks (still readable through the user share).`
new:
```
**Controls:** *Pause* and *Stop* take effect after the current move finishes. *Abort* stops immediately — the item in flight is left split across two disks (still readable through the user share).

**After a run:** when Start rebalance or Start move ends, the tab goes back to a clean page with the result above the cards (successful, error, or stopped) until *Dismiss* or the next dry run. A run counts as successful only when every planned file moved. Each finished run — successful, error, stopped or aborted — is kept under **Job history** on its tab (the last 20), with its per-file results (skips and failures first, with the reason), its move script and its log. A dry run's plan stays until the move starts, another dry run replaces it, or *Discard*. Dry runs and runs with nothing to move are not kept.
```

old: `/usr/local/emhttp/plugins/rebalance/scripts/rebalance-ctl plan|run|pause|resume|stop|abort|status`
new: `/usr/local/emhttp/plugins/rebalance/scripts/rebalance-ctl plan|run|pause|resume|stop|abort|dismiss|status`

old (the line contains backticks, so it is fenced here):
````
Runtime state: `/var/local/rebalance/` (status, plan.tsv, history.tsv, progress). Log: `/var/log/rebalance.log` (previous run in `.log.1`).
````
new:
````
Runtime state: `/var/local/rebalance/` (status, plan.tsv, history.tsv, progress). Log: `/var/log/rebalance.log` (previous run in `.log.1`). Job history: `/boot/config/plugins/rebalance/history/<start>-<mode>/` (meta, history.tsv, moves.sh, rebalance.log), written once when a real run ends; the newest 20 per tab are kept.
````

- [ ] **Step 2: Verify.** `grep -c $'\r' README.md` → `0`; `grep -c 'Job history' README.md` → `2`.

- [ ] **Step 3: Commit** — `git add README.md && git commit -m "README: job history, Dismiss and Discard"`

---

### Final: review [reviewer]

Dispatch `reviewer` on `git diff 7752aeb..dev`. Read closely: `$ENG` (`archive_run`, `prune_history`, `finish_run`, `on_exit`), `$CTL` (`dismiss`), `$INC/status.php` (`?run=` branch, `$runs`), `$INC/script.php`, `$INC/log.php`, `run_id_ok`. Skim: `common.js` (`own`, `renderHead`, `renderRuns`), `common.css`, both `.page` files, `tests/engine_test.sh`, README. Mutating paths (the archive, retention `rm -rf`, dismiss) are reviewed for correctness, not style. Findings become issues or are rejected in the same session; no review report is committed. The CHANGES block, the version bump, the merge to `main` and the release are the owner's.

---

## Risks

- **FAT flash (Unraid `/boot`)**: folder rename (`mv -T`), `cp`, `rm -rf` and `ls` on vfat are exercised only on the box (Checkpoint 1 Message 2 writes its scratch history on `/boot`). A failure there shows as `archives=` counts or a `history could not be saved` banner, never as a stuck page.
- **Flash wear / latency**: one archive (4 small files + one log copy) per real run; the log copy can be several MB for a long Data Move. `status.php` reads up to 40 `meta` files per 3 s poll (page cache serves them after the first read). Revealed by a slow page on a box with a slow flash.
- **Unexpected engine exit** (EXIT with no `FINAL`) is archived as `error` through the same branch as `die`, but no test injects that fault.
- **A second abort while archiving** is ignored (Decision 7); an engine `kill -9` during the archive leaves `.tmp-<pid>` in the history folder (filtered out of the list, never pruned). Revealed by `ls -a` of the history folder.
- **The archived `moves.sh` header still reads "move plan from a dry run, for review only"** (shared `write_move_script` text): accurate about "review only", loose about "dry run".
- **The Log box keeps showing the finished run's last lines** after the page clears (spec did not list it; the log is the current-run log until the next start, as today).
- **The banner replaces the Data Move selection hints** while it is shown (Decision 13): ticking items with a banner up shows no "Tick at least one destination" hint until Dismiss.
- **The dev install replaces the released plugin on the box** until the owner reinstalls a release. The history folder survives an uninstall (the `.plg` remove step deletes only the plugin dir, `/var/local/rebalance` and packages).
- **No JS test harness**: the UI is proven by `node --check`, the Task 7 smoke script and Checkpoint 2.

## Out of scope

- History for dry runs; a clear-history button; export (spec non-goals).
- Recovering or archiving a `stale` run; a Dismiss button on `stale`.
- Any change to what the engine moves, skips or stops on; rebalance-mode behaviour beyond the end-of-run status.
- Clearing the Log box after a run; rewording the archived move script header.
- The `<CHANGES>` block, `<!ENTITY version>`/`md5`, tagging, release, merge to `main`.

## Files per task (strictly in order; each depends on the previous commit)

| Task | Files |
| --- | --- |
| 1 | `scripts/rebalance.sh`, `tests/engine_test.sh` |
| 2 | `scripts/rebalance.sh`, `tests/engine_test.sh` |
| 3 | `include/common.php`, `include/status.php`, `tests/engine_test.sh` |
| 4 | `scripts/rebalance-ctl`, `include/action.php`, `tests/engine_test.sh` |
| 5 | `include/script.php`, `include/log.php`, `tests/engine_test.sh` |
| Checkpoint 1 | none (push with consent; box) |
| 6 | `include/common.js`, `include/common.css`, `DataMove.page` |
| 7 | `include/common.js`, `include/common.css`, `RebalanceMain.page`, `DataMove.page` |
| Checkpoint 2 | none (push with consent; box) |
| Checkpoint 3 | none (box) |
| 8 | `README.md` |

(`scripts/…`, `include/…` and the `.page` files are under `source/usr/local/emhttp/plugins/rebalance/`.)
