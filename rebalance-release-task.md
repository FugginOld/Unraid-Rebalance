# Task: publish the Array Rebalance plugin (first release) and its Community Applications template

You are working for Joe (GitHub: **FugginOld**). Carry out the steps below in order.
Each step ends with a **Check**. If a check fails, **stop and report**; don't improvise
fixes to plugin code or workflows. Show me each command's output as you go.

## Inputs

| What | Where |
|---|---|
| Plugin source (zip) | `Unraid-Rebalance.zip`. Look in the workspace and `~/Downloads`; ask me if you can't find it |
| Plugin repo | `https://github.com/FugginOld/Unraid-Rebalance` (branch `main`) |
| Templates repo | `https://github.com/FugginOld/unraid-templates` (branch `main`) |
| Template to add | `plugins/unraid-balance.xml`, content embedded in Step 7 |

The zip contains one top-level folder, `Unraid-Rebalance/`. Its **contents** belong at the
root of the plugin repo.

## Ground rules

- Use bash (Git Bash on Windows is fine) and the `gh` CLI.
- Never force-push, never rewrite history, never delete branches.
- Keep the plugin repo's existing `LICENSE` (MIT). The zip deliberately doesn't include one.
- Do not edit anything under `source/`, `.github/`, `tests/` or `build.sh`. They're tested as-is.
- Do not commit this task file.

---

## Step 0: Preconditions

```bash
gh auth status
git --version
```

Clone whichever repo isn't already on disk (ask me where I keep repos if unsure):

```bash
gh repo clone FugginOld/Unraid-Rebalance
gh repo clone FugginOld/unraid-templates
```

In both clones, make sure the working tree is clean and on an up-to-date `main`:

```bash
git switch main && git pull --ff-only && git status --short
```

**Check:** `gh` is authenticated as FugginOld, both clones are on `main`, and `git status --short` prints nothing.

---

## Step 1: Unpack the zip into the plugin repo

From the root of the `Unraid-Rebalance` clone:

```bash
tmp=$(mktemp -d)
unzip -q /path/to/Unraid-Rebalance.zip -d "$tmp"
cp -a "$tmp/Unraid-Rebalance/." .        # the trailing /. copies dotfiles (.github, .gitignore, .gitattributes)
rm -rf "$tmp"

# leftovers from earlier drafts, if present
git rm -r --quiet --ignore-unmatch archive pkg_build.sh
rm -rf archive releases pkg_build.sh '{archive,source'
```

**Check:** the repo root contains exactly `.gitattributes .github .gitignore LICENSE README.md
build.sh docs icon.png rebalance.plg source tests`, plus `.git`. There is no `archive/`, no
`pkg_build.sh`, and no folder whose name contains `{`.

---

## Step 2: Line endings (critical)

Every file here runs on Linux. The `.plg`'s install scripts and the bash scripts **must be LF**.
`.gitattributes` enforces this, so renormalize now that it's in place:

```bash
git add --renormalize .
git add -A
git ls-files --eol rebalance.plg build.sh tests/engine_test.sh \
  source/usr/local/emhttp/plugins/rebalance/scripts/rebalance.sh \
  source/usr/local/emhttp/plugins/rebalance/scripts/rebalance-ctl
```

**Check:** every line of the last command shows `i/lf`. If any shows `i/crlf`, stop and report.

---

## Step 3: Local tests (Linux or WSL only)

The integration tests need GNU coreutils/findutils, `rsync` and `php`. **On Linux or WSL:**

```bash
bash tests/engine_test.sh
bash build.sh 0000.00.00 && rm -rf releases
```

**Check:** the tests end with `all checks passed`, and `build.sh` prints an MD5.
**On Windows (non-WSL) or macOS:** skip this step and say so. CI runs the same tests in Step 4.

---

## Step 4: Commit, push, and wait for CI

```bash
git commit -m "Array Rebalance plugin: engine, dashboard, CI release workflow"
git push origin main
sleep 10
run=$(gh run list --workflow=test.yml --branch main --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$run" --exit-status
```

**Check:** the `test` workflow finishes green. If it fails, show me the failing step's log
(`gh run view "$run" --log-failed`) and stop.

---

## Step 5: Cut the first release

The release version comes from the newest changelog block in `rebalance.plg`:

```bash
grep -m1 -o '^###[0-9.a-z]*###' rebalance.plg     # expect: ###2026.09.25###
```

Tag **main's current tip** with exactly that version (a date in the past is fine) and push the tag:

```bash
git pull --ff-only
git tag 2026.09.25
git push origin 2026.09.25
sleep 10
run=$(gh run list --workflow=release.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$run" --exit-status
```

The release workflow runs the tests, builds the package, commits a `Release 2026.09.25` change
to `rebalance.plg` on `main` (version and MD5), and publishes the GitHub release.

**Check:** the `release` workflow finishes green.

**If it fails:** show me `gh run view "$run" --log-failed` and stop. Likely causes:
- *Push to main rejected (403 / protected branch):* repo **Settings → Actions → General →
  Workflow permissions** must allow **Read and write**, or branch protection must allow
  `github-actions[bot]`. Tell me; don't change settings yourself.
- *Before retrying,* check whether the bot's `Release 2026.09.25` commit landed on `main` (`git pull`, `git log -3`).
  - If it **did not** land, delete the tag and retag after the fix:
    `git push origin :refs/tags/2026.09.25 && git tag -d 2026.09.25`.
  - If it **did** land, the same tag can't be reused, because it's no longer main's tip. Stop and ask me.
    The next attempt needs a `###2026.09.25a###` block and tag `2026.09.25a`.

---

## Step 6: Verify the release end to end

```bash
git pull --ff-only
gh release view 2026.09.25 --json tagName,assets -q '.tagName, (.assets[].name)'
grep -E 'ENTITY (version|md5)' rebalance.plg

# download the asset exactly as Unraid will, and compare its MD5 with the one in the plg
url=https://github.com/FugginOld/Unraid-Rebalance/releases/download/2026.09.25/rebalance-2026.09.25-x86_64-1.txz
curl -fsSL "$url" -o /tmp/rb.txz && md5sum /tmp/rb.txz

# the URLs the Community Applications template points at
for f in rebalance.plg README.md icon.png; do
  printf '%-14s %s\n' "$f" "$(curl -s -o /dev/null -w '%{http_code}' "https://raw.githubusercontent.com/FugginOld/Unraid-Rebalance/main/$f")"
done
```

**Check:**
- The release has exactly one asset, `rebalance-2026.09.25-x86_64-1.txz`.
- The `version` entity is `2026.09.25`, and the `md5` entity is a real hash (not all zeros).
- The downloaded file's MD5 **equals** the `md5` entity.
- All three URLs return `200`. raw.githubusercontent.com can lag a few minutes after a push, so retry before reporting a failure.

---

## Step 7: Add the Community Applications template

Only after Step 6 passes. Until then, the `.plg` points at a release that doesn't exist.

In the `unraid-templates` clone, create `plugins/unraid-balance.xml` with exactly this content (LF line endings):

```xml
<?xml version="1.0" encoding="utf-8"?>
<Plugin>
  <Name>Array Rebalance</Name>

  <Overview>
Rebalance your array after large data moves. Moves data between array disks so every
data disk ends up filled to the same percentage of its capacity: a 14 TB disk holds
proportionally more than a 10 TB disk.

Builds a plan first (dry run), then moves whole folders disk-to-disk with rsync, keeping
their paths so user shares are unchanged. Honors each share's included/excluded disks,
never touches cache or pools, and keeps parity valid throughout. Pauses for parity checks
and the mover, and skips items that have open files, were written recently, contain
in-progress downloads or are hardlinked elsewhere (e.g. torrent/media links).

Live dashboard under Settings, User Utilities: overall progress, the current move with
speed and ETA, each disk against its target, the queue, recent moves and the log, with
pause, stop and abort controls.
  </Overview>

  <PluginURL>https://raw.githubusercontent.com/FugginOld/Unraid-Rebalance/main/rebalance.plg</PluginURL>
  <PluginAuthor>FugginOld</PluginAuthor>

  <Support>https://github.com/FugginOld/Unraid-Rebalance/issues</Support>
  <Project>https://github.com/FugginOld/Unraid-Rebalance</Project>
  <ReadMe>https://raw.githubusercontent.com/FugginOld/Unraid-Rebalance/main/README.md</ReadMe>

  <Category>Tools:System</Category>
  <Beta>true</Beta>
  <License>MIT</License>

  <Icon>https://raw.githubusercontent.com/FugginOld/Unraid-Rebalance/main/icon.png</Icon>
</Plugin>
```

Then:

```bash
# PluginURL in the template must equal pluginURL inside the published plg, character for character
grep -o '<PluginURL>[^<]*' plugins/unraid-balance.xml
curl -fsSL https://raw.githubusercontent.com/FugginOld/Unraid-Rebalance/main/rebalance.plg | grep 'ENTITY pluginURL'

git add plugins/unraid-balance.xml
git status --short          # expect only: A  plugins/unraid-balance.xml
git commit -m "Add Array Rebalance plugin template"
git push origin main
```

**Check:** `git status --short` showed only the new file, so nothing else in the templates repo
changed, including `plugins/hbaviewer.xml` and `templates/`. The push succeeded. The two URLs match:
the plg's `pluginURL` entity is written with entities
(`https://raw.githubusercontent.com/&author;/&repo;/main/&name;.plg`), and expands to the same URL as the template's.

---

## Step 8: Report back

Give me a short summary:

| Item | Result |
|---|---|
| Plugin repo pushed (commit SHA) | |
| `test` workflow | pass / fail |
| Release `2026.09.25` published, asset name | |
| MD5 in plg = MD5 of downloaded asset | yes / no |
| raw URLs (`.plg`, README, icon) | 200 / other |
| Template pushed (commit SHA) | |
| Anything skipped (e.g. Step 3 on Windows) | |

Also tell me:
- **When the listing appears:** Community Applications rebuilds its feed periodically, so the app shows up
  under **Apps → search "Array Rebalance"** after the next rebuild, not immediately.
- **The manual install URL**, which I can use right away:
  `https://raw.githubusercontent.com/FugginOld/Unraid-Rebalance/main/rebalance.plg`
