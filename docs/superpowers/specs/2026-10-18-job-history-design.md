# Job history and a clean page after each run - design

Date: 2026-10-18. Applies to both tabs (Array Rebalance, Data Move).

## Intent

After a run finishes, the tab keeps showing it: the status pill, the "N move(s) planned" line, "Last run started...", the "View move script" link and the script panel. The engine only wipes that state when the *next* run starts (`rebalance.sh:464`), so the page cannot go back to idle on its own. The owner wants a clean page ready for the next job, with the finished job kept somewhere they can look it up. Today nothing is kept across runs: "Recently completed" shows the last 6 files of the last run only.

## Behavior (decided by the owner)

- **Successful run** (every planned file moved, nothing skipped): the page clears itself and shows a "Move successful" status. The run goes into history.
- **Error that stops the job** (engine `die`, rsync failure, unexpected engine exit): the job stops, the page clears, and the status says there was an error and to check the job history. The run goes into history with the error recorded.
- **A problem with one file only**: that file is skipped and the job continues (the engine already does this). Any skipped or failed file means the run ends with the same error-style status, not "Move successful". "Successful" means every planned file moved.
- **Status banner**: stays until the owner dismisses it (small dismiss button) or starts the next dry run or move.
- **Dry run never started**: the plan, script and "Dry run ready" stay until the move starts or another dry run replaces them. Add a Discard button on the planned state that clears it. Dry runs never go into history.
- **History pane on each tab**: last 20 runs per tab (Array Rebalance runs on its tab, Data Move runs on the other; the tabs already ignore each other's mode, `common.js:72`). Stored on the flash drive so it survives a reboot.

## Goals / non-goals / anti-goals

- Goals: a clean idle page after every finished run; a findable record of what happened, including why a file was skipped or a run stopped.
- Non-goals: history for dry runs; a "clear history" button (the 20-run cap bounds it); export; recovering a `stale` run (engine killed with no chance to archive - behaves as today); any change to what the engine moves, skips, or stops on.
- Anti-goals: writing to flash during a run or per file (one write per finished run only); a failed archive turning a good run into an error or leaving the page stuck on the old run.

## Design calls made by the designer (not yet confirmed by the owner)

1. **"Recently completed" stays** as the live per-file list while a run is active, and shows "Nothing yet." when idle. The History pane is new and sits below it. (Earlier in the conversation this was described as being replaced; keeping it avoids losing the live view.)
2. A Data Move that leaves items out or behind (`plan_skipped + plan_left`, `rebalance.sh:615`) ends with the same error-style status, worded "Finished, but some items were not moved - check the job history".
3. "Stopped by user" and "Aborted by user" are archived with result `stopped` / `aborted`. The page clears with a neutral status "Stopped - see job history".
4. A run whose plan has nothing to move ("Nothing to move", `rebalance.sh:447-450`) is not archived; its message shows as today.
5. A dry run that errors (e.g. "Array is not started") is not archived. Its error shows as today, now with the dismiss button.
6. If the archive write fails, the run still clears and the banner adds "history could not be saved"; the failure is logged.
7. Retention: oldest runs beyond 20 per kind are deleted after each archive.
8. **Dismiss and Discard** are a new `rebalance-ctl` subcommand (`dismiss`), run under the `$RUN/lock` flock so it cannot race an engine that is starting. `action.php` calls it like it calls the other ctl commands. It resets `state` to `idle` and drops `msg`, `warn` and the `last_*` keys. This is also how the non-archived end states (dry-run error, "Nothing to move") are dismissed.
9. **Failed real runs are archived even if nothing moved** (e.g. "Array is not started", the Data Move "cannot be moved" stop), because the banner tells the owner to check the history for the error. Dry-run failures are not archived (call 5).
10. **Array Rebalance `plan_skipped`** (items left out of the plan as open or hardlinked) does not make a run an error. Only a skipped or failed file in the move loop does. Data Move keeps call 2.
11. **Per-file results of a past run** come from a separate endpoint (`status.php?run=<id>`-style or a new include file, builder's choice) with a line cap and the same id validation, not from the polled status. `status.php` returns run meta only.
12. **`last_mode`**: the idle status after a run keeps `last_mode`, and the banner and Dismiss apply only on the tab that matches it. The other tab does not show the banner.

## How it works (constraints for the builder)

- **State today**: engine state lives in `/var/local/rebalance` (RAM): `status` (key=value, rewritten by `st_set` from an in-memory array, so a fresh engine process starts with none of the old keys), `plan.tsv`, `history.tsv` (per-file result lines), `start.tsv`, `moves.sh`. The log is `/var/log/rebalance.log`, rotated to `.1` at each start, so it holds exactly the current run. Final states set by the engine: `done`, `stopped`, `planned`, `aborted`, `error`; `status.php` adds `stale`.
- **Where**: archive in the engine's EXIT path (`on_exit`, `rebalance.sh:467`) for modes `run` and `move-run` only, after `FINAL` is known. `die` sets `error` and exits, the TERM trap sets `aborted`; both reach `on_exit`.
- **Archive format**: one folder per run under `/boot/config/plugins/rebalance/history/<start-epoch>-<mode>/` holding a small key=value meta file (mode, started, ended, result, summary message, counts, kib), the run's `history.tsv`, the move script (a real run does not write `moves.sh` today - generate it from `plan.tsv` with `write_move_script`), and a copy of the log. An env override for the history dir is needed so tests can use a temp dir (as `RB_RUN` does).
- **After archiving**: remove the run files and leave the status as `idle` plus `last_result` (`success`, `error`, `stopped`, `aborted`), `last_msg` and `last_id` (the archive folder name). Starting a new engine process drops these automatically. Dismiss (a new action in `action.php`, same method and CSRF handling as the existing actions) deletes the `last_*` keys. Discard (planned state) removes the plan files and resets the status to idle.
- **`status.php`**: add a `last` object from those keys and a `runs` list (newest first, max 20, filtered to the requesting tab's kind) read from the history dir. Run ids are validated (`^[0-9]+-[a-z-]+$`) wherever they are used in a path.
- **Script and log of a past run**: extend `script.php` and `log.php` to serve an archived run by validated id; without an id they behave as today.
- **UI**: banner area in the existing message line (`common.js:125` area) for `last`; a History pane under the cards on both pages (shared code in `common.js`, markup in each `.page`); each entry shows start time, result, move count, size, and expands to the per-file results (skips and failures listed first, with reasons) with links to that run's script and log. Spacing follows the compact style just shipped (`common.css`).
- **Conventions**: LF line endings everywhere (Unraid target); no external dependencies; engine changes are covered in `tests/engine_test.sh` and each new assertion is mutation-tested; no key or secret handling is involved.

## Verification

- Unit/engine tests (sandbox): success, error, skip-one-file, stopped, aborted, nothing-to-move, dry run (not archived), archive failure, retention at 21 runs, id validation.
- On the box, one step at a time (the owner runs commands and pastes output): (1) engine + status change with a small real Data Move, then confirm the page is idle with the banner and the archive folder exists on `/boot`; (2) the UI pane; (3) error path with a forced skip.

## Left to the builder

File layout inside the archive, the exact wording of the banners beyond the phrases above, the history pane's visual design within the existing compact style, and how the tests fake an rsync failure.
