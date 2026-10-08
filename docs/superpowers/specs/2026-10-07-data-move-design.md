# Data Move — design

Date: 2026-10-07 · Branch: `dev` · Mockup: <https://claude.ai/artifact/Dc2EdwaU3tyqzKEZchAVjj> (v3)

## Goal

A second tab, **Data Move**, beside the existing **Array Rebalance** tab. The user ticks what to move
(a whole disk, a folder, or individual files) in a Source pane, ticks one or more receiving disks in a
Destination pane, dry-runs, then starts. Moves keep their path (`/mnt/diskA/<rel>` → `/mnt/diskB/<rel>`),
so user shares look identical afterwards. Every safety property of a rebalance run carries over unchanged.

Success: a user can gather a series split across disks onto one disk, or empty a disk onto several others,
from the webGui, with the same progress, pause/stop/abort and log they get from a rebalance.

## Decisions (agreed)

| # | Decision |
| --- | --- |
| D1 | Placement across several destinations: **largest item first, onto the ticked disk with the most room left** (after the D2 preference). |
| D2 | Same path already on a destination: **merge, never overwrite.** A ticked disk that already holds the item's folder is preferred. Any file that exists at the same path on both sides is a conflict: the dry run lists it and the run refuses to start. |
| D3 | A disk can give and receive in one move. **An item never goes back to its own disk.** Only a disk ticked in full is unavailable as a destination. |
| D4 | One engine, one lock, one job at a time. A rebalance and a move never run together. |
| D5 | Anything that doesn't fit (or conflicts) ends the plan in an error listing those items; nothing moves. Unlike a rebalance, nothing is silently left out. |
| D6 | Destination pane has a **Select all disks** checkbox (tri-state, skips disks ticked in full, locked while running). |
| D7 | Settings stay on the Array Rebalance tab and apply to both. Data Move has no settings of its own. |

## Pages

- New parent page `ArrayRebalance.page` (`Menu="Utilities"`, `Type="xmenu"`, tabbed). Tabs:
  1. `Rebalance.page` — unchanged content; menu line changes to `ArrayRebalance:1`. Opens by default.
  2. `DataMove.page` — new; `ArrayRebalance:2`.
- The `<style>` block and the shared JS (formatters, `el`/`svg`, `post`, `STATES`, `renderHead`,
  `renderChips`, `renderOverall`, `renderCurrent`, `renderLists`, `renderLog`, `poll`) move out of
  `Rebalance.page` into `include/common.css` and `include/common.js`. Both pages load them. Rebalance
  keeps `renderDisks` and the settings form; Data Move adds the two panes.
- URL changes from `/Settings/Rebalance` to the parent page's. Accepted.
- **Hardware check:** the exact xmenu/tab header keys are confirmed on the box before building on them.

### Data Move layout (top to bottom)

Header + actions · message bar · status chips · Overall progress | Now moving · **Up next | Recently
completed** (one row, equal widths) · **Source | Destination** (one row, equal widths, each scrolls
internally) · Log · one line pointing to Settings on the Rebalance tab.

States: **Selecting** (idle/done/stopped/aborted/error) and **Active** (planning/running/paused, plus
`planned` for a move dry run). In Selecting, Overall progress shows the selection total, Moves, Won't fit,
Destinations and estimated duration, and Up next shows a live client-side preview of the plan. In Active
both panes are read-only and the cards behave exactly as on the Rebalance tab.

### Source pane

- Tree: disk → share → folder → … → file. Children load one folder at a time from `browse.php` when
  expanded. Disks come from `status.php` (`disks[]`, already excludes `EXCLUDE_DISKS`).
- Tri-state checkbox per row. Ticking a node ticks its subtree, including children not yet loaded.
- Disk rows show a mini fill bar with the ticked amount striped, and `−<size>` outgoing.
- Shares excluded by settings (`EXCLUDE_SHARES`/`INCLUDE_SHARES`) are shown but not tickable, labelled
  "excluded in settings". Names containing a newline or tab are not listed (same rule as the planner).
- Footer: item count, source disks, total ticked.
- What is sent to the server is the minimal set of fully-ticked nodes (a ticked folder, never its files).

### Destination pane

- Every disk: checkbox, name, size, fill bar (used + incoming striped + minimum-free-space line),
  fill % after, incoming size. Disks ticked in full on the Source side are greyed and tagged `source`.
- **Select all disks** checkbox above the list (D6), with "N of M available" beside it.
- Footer: disks ticked, usable space above the minimum-free-space floor.

## Backend

### `include/browse.php` (GET, new)

`?disk=diskN&path=<rel>` → `{ok, entries:[{name, type:"dir"|"file", kib, excluded}]}` for one folder.

- `disk` must match `^disk[0-9]+$` and not be in `EXCLUDE_DISKS`.
- `path` is relative; rejected if it has a `..` component, a leading `/`, NUL, newline or tab.
  `realpath("/mnt/$disk/$path")` must start with `/mnt/$disk/` (or equal it for the root).
- Sizes: `du -sk` per child folder, `stat` for files. Hidden entries (`.*`) are skipped, as in the planner.
- Read-only. Browsing spins the disk up; that is accepted.
- Test hook: honours `RB_MNT` like `status.php`.

### `include/action.php`

New actions `move-plan` and `move-run`. POST fields: `items` (JSON array of `{disk, rel}`; `rel` may be
empty for a whole disk) and `dests` (JSON array of disk names). Validation, all reply 400 on failure:

- at least one item and one destination; at most 10 000 items;
- every disk name matches `^disk[0-9]+$`; every `rel` passes the same path rules as `browse.php` and exists;
- no item is inside another item (the client already sends a minimal set; the server re-checks).

On success it writes `/var/local/rebalance/selection.tsv` atomically (tmp + `mv`), then runs
`rebalance-ctl move-plan|move-run`.

`selection.tsv` lines: `item<TAB>diskN<TAB>rel` and `dest<TAB>diskN`.

### `scripts/rebalance-ctl`

`move-plan` and `move-run` join `plan|run` in the start branch (same "already running" refusal, D4).

### `scripts/rebalance.sh`

`MODE` gains `move-plan` and `move-run`. Everything before the planner (lock, status init, array-started
check, `read_disks`, `start.tsv`) and everything after it (dry-run script, EXECUTE, AFTER report, final
state) is shared. Only the PLAN section branches:

- **rebalance modes:** the current target/greedy planner, unchanged.
- **move modes:** the selection planner:
  1. Read `selection.tsv`. Re-validate every line (the engine does not trust the file): disk is in
     `DISKS`, path exists, no newline/tab. A bad line is a `die`.
  2. **Expand to units.** An entry whose depth is ≤ `ITEM_DEPTH` (a whole disk, a share, or a folder above
     item depth) expands to the items at `ITEM_DEPTH` beneath it, using the same `find` filters as
     `build_candidates`, skipping ineligible shares. Deeper entries are units as they are. Units are sized
     with `du -sk`.
  3. `item_static_ok` per unit, as now; a failing unit is a `PLAN-SKIP` and counts toward left-out.
  4. **Place,** largest first. Candidates are ticked destinations that are not the unit's own disk (D3),
     not ticked in full, allowed by `share_allows`, and have `AVAIL − size ≥ MIN_FREE_KB`. Prefer a
     candidate where the unit's item folder (`<share>/<item>` at `ITEM_DEPTH`) already exists (D2);
     among equals, most `AVAIL` (D1). Update the simulated `AVAIL` after each placement.
  5. **Conflicts.** For a placed unit whose path exists on the destination: a file unit is a conflict; a
     folder unit conflicts if any file below it exists at the same relative path on the destination, or a
     file/folder type differs.
  6. Write `plan.tsv` in the existing `idx sz src dst rel` format.
  7. If any unit is unplaced or conflicting: log each as `PLAN-NOFIT` / `PLAN-CONFLICT`, set
     `state error` with a message naming the count and pointing to the log, exit (D5). Nothing moves.
  `TOLERANCE_PCT` and `MAX_MOVE_GB` do not apply to a move.
- **EXECUTE, move modes only:** the pre-move check `already exists on $dst` becomes the step-5 conflict
  check, run live. A conflict found live is a `SKIP`, like any other live check.
- **rsync:** `--ignore-existing` is added to `rsync_argv` (the single definition, used by both modes).
  If a clashing file appears between the live check and the copy, it is not overwritten; the source copy
  remains, the existing "source still exists after move" check fails, and the run stops.
  **Open risk, test first:** confirm with real rsync that `--remove-source-files` does not delete a source
  file that `--ignore-existing` skipped. If it does, this guard is wrong and is replaced before anything
  else is built on it.
- Status: `mode` already carries `MODE`; `status.php` passes it through. Log header reads
  `Data Move - mode: move-run` for move modes.

### `include/status.php`

No new fields. `mode` already exists, and the queue and history already come from `plan.tsv` and
`history.tsv`. Each page decides which tab owns the active (or last) run from `mode`: `plan`/`run` is
Rebalance, `move-plan`/`move-run` is Data Move.

## Cross-tab behaviour

- While a run is active, the tab that does not own it disables its start buttons and shows a message bar:
  "A data move is running. View it on the Data Move tab." (or the rebalance equivalent), linking to it.
- Each tab shows the last run of its own kind in Recently completed. The engine keeps one `history.tsv`, so
  when the last run was the other kind, that list shows "Nothing yet." for this tab.

## Error handling

- Every user-supplied value is validated in `action.php` and again in the engine.
- Plan errors (D5) leave `plan.tsv` written, so the move script and log show what would have moved.
- The source-removal and stop-on-first-failure behaviour of EXECUTE is unchanged.

## Testing

`tests/engine_test.sh`, against the existing fake array, real rsync. New cases:

1. rsync `--ignore-existing` + `--remove-source-files` keeps the source of a skipped file (the open risk above).
2. Move a folder: lands at the same path on the destination, source gone.
3. Move a single file.
4. A whole share ticked expands to items at `ITEM_DEPTH` and spreads across two destinations, largest
   first to most room.
5. Merge: the destination already holds the item folder with different files; it is preferred over a
   roomier disk and the files merge.
6. Conflict: a same-named file on the destination → state `error`, nothing moved, both copies intact.
7. A unit never goes back to its own disk when that disk is also a destination.
8. The minimum-free-space floor: a unit that would cross it is unplaced → state `error`, nothing moved.
9. A bad `selection.tsv` line (unknown disk, `..`, missing path) → `die`.
10. `browse.php`: rejects `..`, an absolute path, a non-`diskN` disk; lists a folder with sizes.
11. `action.php` `move-plan`: rejects a nested item pair and an empty destination list.

Each new assertion gets a mutation pass: break the code it guards and see it fail.

On the box (one at a time, each before building further): tab layout renders; browsing a large share
responds in reasonable time; one real dry run; one real move that merges into an existing folder.

## Out of scope

Moves to or from cache/pools or `/mnt/user`; splitting one item across disks; overwrite options;
scheduling; Data Move-specific settings.
