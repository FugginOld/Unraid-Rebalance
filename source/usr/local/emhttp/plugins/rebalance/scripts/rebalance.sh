#!/bin/bash
# Array Rebalance engine
#   rebalance.sh plan       -> build the move plan only (dry run)
#   rebalance.sh run        -> build the plan, then execute it
#   rebalance.sh move-plan  -> Data Move: plan the ticked items in $RUN/selection.tsv (dry run)
#   rebalance.sh move-run   -> Data Move: plan the ticked items, then execute
# Started/controlled by rebalance-ctl. State for the web UI lives in $RUN.
#
# Target fill % = total used / total capacity of the included array disks.
# Items (folders at ITEM_DEPTH inside each share) move largest-first from disks
# above target to disks below it, disk-to-disk, keeping the same path, so user
# shares are unchanged. rsync --remove-source-files deletes a source file only
# after it has been copied. Never touches /mnt/user, cache or pools.

PLUGIN=rebalance
EMHTTP=/usr/local/emhttp/plugins/$PLUGIN
CFG=${RB_CFG:-/boot/config/plugins/$PLUGIN/$PLUGIN.cfg}
DEFAULT_CFG=$EMHTTP/default.cfg
RUN=${RB_RUN:-/var/local/$PLUGIN}
LOG=${RB_LOG:-/var/log/$PLUGIN.log}
MNT=${RB_MNT:-/mnt}
VAR_INI=${RB_VAR_INI:-/var/local/emhttp/var.ini}
SHARE_CFG_DIR=${RB_SHARE_CFG:-/boot/config}
NOTIFY_BIN=${RB_NOTIFY_BIN:-/usr/local/emhttp/webGui/scripts/notify}
MDCMD=/usr/local/sbin/mdcmd
BUSY_POLL_S=30   # parity/mover re-check while paused; RB_BUSY_POLL_S shortens it in tests only (RB_MNT is never set in production)
[[ -n $RB_MNT && $RB_BUSY_POLL_S =~ ^[1-9][0-9]*$ ]] && BUSY_POLL_S=$RB_BUSY_POLL_S
QUOTE_LC=$(locale -a 2>/dev/null | grep -m1 -ixE 'c\.utf-?8|en_us\.utf-?8')   # a UTF-8 locale this box has, so shown commands keep accented names readable; none = escaped
MODE=$1
MOVE=false; [[ $MODE == move-plan || $MODE == move-run ]] && MOVE=true   # Data Move: only the PLAN section differs

############################## CONFIG ##############################
TOLERANCE_PCT=1; ITEM_DEPTH=1; MIN_FREE_GB=50; MAX_MOVE_GB=0
EXCLUDE_SHARES="appdata,system,domains,isos"; INCLUDE_SHARES=""; EXCLUDE_DISKS=""
TURBO_WRITE=true; PAUSE_ON_PARITY=true; MAX_PAUSE_HOURS=48; NOTIFY=true
SKIP_OPEN_FILES=true; SKIP_HARDLINKED=true; SKIP_RECENT_MIN=15
SKIP_PATTERNS="*.part,*.!qB,*.partial~,*.tmp,*.unpack,*.filepart,*.crdownload,*.nzb,*.bts"

load_cfg() {  # whitelisted keys only; values are never evaluated
  local f k v
  for f in "$DEFAULT_CFG" "$CFG"; do
    [[ -f $f ]] || continue
    while IFS='=' read -r k v || [[ -n $k ]]; do
      k=${k//[[:space:]]/}; v=${v%$'\r'}; v=${v#\"}; v=${v%\"}
      case $k in
        TOLERANCE_PCT|ITEM_DEPTH|MIN_FREE_GB|MAX_MOVE_GB|MAX_PAUSE_HOURS|SKIP_RECENT_MIN)
          [[ $v =~ ^[0-9]+$ ]] && printf -v "$k" '%s' "$v" ;;
        TURBO_WRITE|PAUSE_ON_PARITY|SKIP_OPEN_FILES|SKIP_HARDLINKED|NOTIFY)
          [[ $v == true || $v == false ]] && printf -v "$k" '%s' "$v" ;;
        EXCLUDE_SHARES|INCLUDE_SHARES|EXCLUDE_DISKS|SKIP_PATTERNS)
          printf -v "$k" '%s' "$v" ;;
      esac
    done < "$f"
  done
  (( ITEM_DEPTH >= 1 )) || ITEM_DEPTH=1
}

############################## HELPERS ##############################
log()    { printf '[%(%F %T)T] %s\n' -1 "$*"; }
notify() { $NOTIFY && [[ -x $NOTIFY_BIN ]] && "$NOTIFY_BIN" -e "Array Rebalance" -s "Array Rebalance" -d "$2" -i "$1" >/dev/null 2>&1; return 0; }
in_csv() { [[ ",$2," == *",$1,"* ]]; }
human() {
  local k=$1 s=""
  (( k < 0 )) && { s="-"; k=$(( -k )); }
  awk -v k="$k" -v s="$s" 'BEGIN{split("KiB MiB GiB TiB PiB",u);i=1;while(k>=1024&&i<5){k/=1024;i++}printf "%s%.1f %s",s,k,u[i]}'
}
cfg_val() { sed -n 's/\r$//; s/^'"$1"'="\(.*\)"/\1/p' "$2" 2>/dev/null; }   # CRLF-safe Unraid cfg reader

# ---- status file for the UI (key=value, rewritten atomically) ----
declare -A ST
st_set() {
  while (( $# >= 2 )); do ST[$1]=$2; shift 2; done
  local k tmp="$RUN/status.tmp"
  { for k in "${!ST[@]}"; do printf '%s=%s\n' "$k" "${ST[$k]//$'\n'/ }"; done
    printf 'updated=%s\n' "$EPOCHSECONDS"; } > "$tmp" && mv -f "$tmp" "$RUN/status"
}

FINAL=""
die() { log "ERROR: $*"; FINAL=error; st_set state error msg "$*"; notify alert "$*"; exit 1; }

############################## WRITE METHOD ##############################
ORIG_WM=""; TURBO_STATE=off
get_wm() { local v; v=$(cfg_val md_write_method "$VAR_INI"); [[ -z $v ]] && v=$(cfg_val md_write_method /boot/config/disk.cfg); echo "$v"; }

enable_turbo() {
  $TURBO_WRITE || return
  if [[ ! -x $MDCMD ]]; then log "WARNING: mdcmd not found - write method unchanged"; TURBO_STATE=unavailable
  else
    ORIG_WM=$(get_wm)
    [[ $ORIG_WM =~ ^[0-9]+$ ]] || { log "Write method setting was '${ORIG_WM:-blank}' - will restore as 0 (read/modify/write)"; ORIG_WM=0; }
    # Always push to the driver: var.ini can say 1 while the driver still does read/modify/write
    if "$MDCMD" set md_write_method 1 >/dev/null 2>&1; then
      TURBO_STATE=on; log "Reconstruct write (turbo) applied to the driver (setting was $ORIG_WM)"
    else
      TURBO_STATE=failed; ORIG_WM=""; log "WARNING: failed to set reconstruct write - continuing"
    fi
  fi
  st_set turbo "$TURBO_STATE"
}

restore_wm() {
  [[ -z $ORIG_WM ]] && return
  if "$MDCMD" set md_write_method "$ORIG_WM" >/dev/null 2>&1; then log "Write method restored to $ORIG_WM"
  else log "WARNING: could not restore md_write_method - check Settings > Disk Settings"; fi
  ORIG_WM=""
}

############################## ARRAY STATE ##############################
busy_reason() {
  grep -q '^mdState="STARTED"' "$VAR_INI" 2>/dev/null || { echo "array stopped"; return; }
  grep -q '^mdResyncPos="0"' "$VAR_INI" 2>/dev/null || { echo "parity check/rebuild"; return; }
  if [[ -f /var/run/mover.pid ]] && kill -0 "$(cat /var/run/mover.pid 2>/dev/null)" 2>/dev/null; then
    echo "mover"; return
  fi
}

control_word() { cat "$RUN/control" 2>/dev/null; }
STOP_REQ=0

# paused_s = pause time already over, paused_since = start of the current pause (UI subtracts both from elapsed)
PAUSED_S=0; PAUSE_T0=0
pause_begin() { PAUSE_T0=$EPOCHSECONDS; st_set state paused pause_reason "$1" paused_since "$PAUSE_T0"; }
pause_end() { PAUSED_S=$(( PAUSED_S + EPOCHSECONDS - PAUSE_T0 )); st_set state running pause_reason "" paused_since "" paused_s "$PAUSED_S"; }

check_control() {  # returns 1 when the run should end
  local c; c=$(control_word)
  [[ $c == stop ]] && { STOP_REQ=1; return 1; }
  [[ $c == pause ]] || return 0
  log "PAUSED by user"; pause_begin user
  while c=$(control_word); [[ $c == pause ]]; do sleep 3; done
  [[ $c == stop ]] && { STOP_REQ=1; return 1; }
  # keep the file: a leftover "resume" reads as continue, and a stop may already have replaced it
  log "RESUMED by user"; pause_end
}

wait_until_clear() {  # returns 1 if a stop was requested while waiting
  local reason start=$SECONDS
  reason=$(busy_reason); [[ -z $reason ]] && return 0
  [[ $reason == "array stopped" ]] && die "Array was stopped during the run"
  $PAUSE_ON_PARITY || return 0
  log "PAUSED: $reason in progress - waiting"
  pause_begin "$reason"; notify normal "Paused: $reason in progress"
  while reason=$(busy_reason); [[ -n $reason ]]; do
    [[ $reason == "array stopped" ]] && die "Array was stopped during the run"
    [[ $(control_word) == stop ]] && { STOP_REQ=1; return 1; }
    (( SECONDS - start > MAX_PAUSE_HOURS * 3600 )) && die "Paused over ${MAX_PAUSE_HOURS}h waiting on $reason"
    sleep "$BUSY_POLL_S"
  done
  log "RESUMED after $(( (SECONDS - start) / 60 )) min"; pause_end
}

############################## SHARE RULES ##############################
declare -A ALLOW_CACHE
share_eligible() {
  [[ $1 == .* ]] && return 1
  [[ -n $EXCLUDE_SHARES ]] && in_csv "$1" "$EXCLUDE_SHARES" && return 1
  [[ -n $INCLUDE_SHARES ]] && ! in_csv "$1" "$INCLUDE_SHARES" && return 1
  return 0
}
share_allows() {  # share disk
  local key="$1|$2" cfg="$SHARE_CFG_DIR/shares/$1.cfg" inc exc rc=0
  [[ -n ${ALLOW_CACHE[$key]} ]] && return "${ALLOW_CACHE[$key]}"
  if   [[ -n $GLOBAL_EXC ]] && in_csv "$2" "$GLOBAL_EXC"; then rc=1
  elif [[ -n $GLOBAL_INC ]] && ! in_csv "$2" "$GLOBAL_INC"; then rc=1
  elif [[ -f $cfg ]]; then
    inc=$(cfg_val shareInclude "$cfg"); exc=$(cfg_val shareExclude "$cfg")
    if   [[ -n $exc ]] && in_csv "$2" "$exc"; then rc=1
    elif [[ -n $inc ]] && ! in_csv "$2" "$inc"; then rc=1
    fi
  fi
  ALLOW_CACHE[$key]=$rc; return $rc
}

############################## ITEM SAFETY ##############################
declare -A OPEN_INODES; OPEN_STAMP=-9999
refresh_open_inodes() {
  (( SECONDS - OPEN_STAMP < 10 )) && return
  OPEN_INODES=(); OPEN_STAMP=$SECONDS
  local dev ino
  while read -r dev ino; do [[ -n $ino ]] && OPEN_INODES["$dev:$ino"]=1; done < <(
    find /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 -print0 2>/dev/null | xargs -0 -r stat -L -c '%d %i' 2>/dev/null)
}
item_open() {
  local dev ino; refresh_open_inodes
  while read -r dev ino; do [[ -n ${OPEN_INODES["$dev:$ino"]} ]] && return 0
  done < <(find "$1" -type f -printf '%D %i\n' 2>/dev/null)
  return 1
}
item_external_links() {
  local cnt ino nl
  while read -r cnt ino nl; do (( cnt < nl )) && return 0
  done < <(find "$1" -type f -links +1 -printf '%i %n\n' 2>/dev/null | sort | uniq -c)
  return 1
}
item_recent() {
  (( SKIP_RECENT_MIN <= 0 )) && return 1
  [[ -n $(find "$1" -newermt "-$SKIP_RECENT_MIN minutes" -print -quit 2>/dev/null) ]]
}
item_pattern() {
  local p; [[ -z $SKIP_PATTERNS ]] && return 1
  IFS=',' read -ra _pats <<< "$SKIP_PATTERNS"
  for p in "${_pats[@]}"; do [[ -n $(find "$1" -name "$p" -print -quit 2>/dev/null) ]] && return 0; done
  return 1
}
item_static_ok() {   # checks that are stable enough to apply while planning
  local -n _r1=$2
  if item_pattern "$1"; then _r1="in-progress file"; return 1; fi
  if $SKIP_HARDLINKED && item_external_links "$1"; then _r1="external hardlink"; return 1; fi
  return 0
}
item_live_ok() {     # checks that must be made right before the move
  local -n _r2=$2
  item_static_ok "$1" _r2 || return 1
  if item_recent "$1"; then _r2="modified <${SKIP_RECENT_MIN}m ago"; return 1; fi
  if $SKIP_OPEN_FILES; then OPEN_STAMP=-9999; item_open "$1" && { _r2="file open"; return 1; }; fi
  return 0
}

############################## DISKS ##############################
declare -A SIZE USED AVAIL TARGET TOL
DISKS=()
read_disks() {
  local d s u a
  DISKS=()
  while read -r d; do
    [[ -n $RB_MNT ]] || mountpoint -q "$MNT/$d" || continue
    [[ -n $EXCLUDE_DISKS ]] && in_csv "$d" "$EXCLUDE_DISKS" && continue
    read -r s u a < <(df -k --output=size,used,avail "$MNT/$d" | tail -1)
    SIZE[$d]=$s; USED[$d]=$u; AVAIL[$d]=$a; DISKS+=("$d")
  done < <(for p in "$MNT"/disk[0-9]*; do [[ -d $p ]] && echo "${p##*/}"; done | sort -V)
}
df_avail() { df -k --output=avail "$MNT/$1" | tail -1 | tr -d ' '; }

report() {
  log "$1  (target fill: $(awk -v p="$ratio_ppm" 'BEGIN{printf "%.2f", p/10000}')%)"
  printf '  %-8s %12s %12s %7s %12s %12s\n' Disk Size Used Used% Target Delta
  local d
  for d in "${DISKS[@]}"; do
    printf '  %-8s %12s %12s %6s%% %12s %12s\n' "$d" "$(human "${SIZE[$d]}")" "$(human "${USED[$d]}")" \
      "$(awk -v u="${USED[$d]}" -v s="${SIZE[$d]}" 'BEGIN{printf "%.2f", u*100/s}')" \
      "$(human "${TARGET[$d]}")" "$(human $(( USED[$d] - TARGET[$d] )))"
  done
}

item_paths() {   # dir depth -> NUL-separated paths exactly depth levels below dir; hidden names and paths with a newline or tab never appear
  find "$1" -mindepth "$2" -maxdepth "$2" ! -name '.*' ! -path $'*\n*' ! -path $'*\t*' -print0
}
build_candidates() {  # disk -> "sizeKiB<TAB>path" NUL records, largest first
  local d=$1 dir share
  for dir in "$MNT/$d"/*/; do
    [[ -d $dir ]] || continue
    share=${dir%/}; share=${share##*/}
    share_eligible "$share" || continue
    item_paths "$MNT/$d/$share" "$ITEM_DEPTH" | xargs -0 -r du -sk --null -- 2>/dev/null
  done | sort -z -t$'\t' -k1,1nr > "$RUN/cand.$d"
}

############################## MOVE ##############################
progress_reader() {  # rsync --info=progress2 emits CR-separated updates
  local line last=-10
  while IFS= read -r -d $'\r' line; do
    [[ $line =~ ^[[:space:]]*([0-9,]+)[[:space:]]+([0-9]+)%[[:space:]]+([0-9.]+)([kMGT]?B)/s ]] || continue
    (( SECONDS - last < 2 )) && continue
    last=$SECONDS
    printf '%s %s %s %s %s\n' "${BASH_REMATCH[1]//,/}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
      "${BASH_REMATCH[4]}" "$EPOCHSECONDS" > "$RUN/progress.tmp" && mv -f "$RUN/progress.tmp" "$RUN/progress"
  done
}
rsync_argv() {  # src dst rel -> RSYNC_ARGV: the one definition of the move command; RSYNC_LINE: the same argv, shell-quoted
  RSYNC_ARGV=(rsync -aHAX --remove-source-files --relative --ignore-existing --info=progress2 --no-inc-recursive "$MNT/$1/./$3" "$MNT/$2/")   # --ignore-existing: never overwrite a file on the destination
  LC_ALL=${QUOTE_LC:-C} printf -v RSYNC_LINE '%q ' "${RSYNC_ARGV[@]}"; RSYNC_LINE=${RSYNC_LINE% }   # C always exists: escaped, never a setlocale warning
}
run_rsync() {  # src dst rel
  rsync_argv "$@"
  st_set cur_cmd "$RSYNC_LINE"   # the dashboard shows the argv that runs on the next line
  "${RSYNC_ARGV[@]}" </dev/null | progress_reader
  return "${PIPESTATUS[0]}"
}
history() {  # idx result reason kib src dst start end rel
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$RUN/history.tsv"
}
write_move_script() {  # plan.tsv -> moves.sh: the dry run's moves as the exact commands, to read; nothing runs it
  local idx sz src dst rel
  { printf '%s\n' '#!/bin/bash' \
      '# Array Rebalance - move plan from a dry run, for review only.' \
      '# Start rebalance in the dashboard rebuilds the plan from current disk usage,' \
      '# so the real run may differ from this list.' \
      '# Running these commands yourself bypasses the engine safety checks: open-file and' \
      '# hardlink skips, the parity and mover pause, collision checks, per-move' \
      '# verification and empty-folder cleanup.' \
      'echo "Review only - start the rebalance from the dashboard"; exit 1'
    while IFS=$'\t' read -r idx sz src dst rel; do
      rsync_argv "$src" "$dst" "$rel"
      printf '\n# %s  %s  %s -> %s\n%s\n' "$idx" "$(human "$sz")" "$MNT/$src/$rel" "$MNT/$dst/" "$RSYNC_LINE"
    done < "$RUN/plan.tsv"
  } > "$RUN/moves.sh"
}

############################## DATA MOVE ##############################
SEL_ITEMS=(); SEL_DESTS=(); declare -A FULL_SRC
bad_rel() { [[ $1 == /* || $1 == */ || $1 == *//* || /$1/ == */./* || /$1/ == */../* ]]; }   # true for an absolute path or an empty, . or .. part
read_selection() {   # $RUN/selection.tsv -> SEL_ITEMS ("disk<TAB>rel"), SEL_DESTS, FULL_SRC. The engine does not trust the file: any bad line is fatal
  local kind d rel extra p base a
  local -A seen
  [[ -f $RUN/selection.tsv ]] || die "Bad selection: $RUN/selection.tsv is missing"
  while IFS=$'\t' read -r kind d rel extra || [[ -n $kind ]]; do
    [[ -z $extra ]] || die "Bad selection: a line has more than three fields"
    [[ $kind == item || $kind == dest ]] || die "Bad selection: unknown line '$kind'"
    [[ -n $d && -n ${SIZE[$d]} ]] || die "Bad selection: $d is not an included array disk"
    if [[ $kind == dest ]]; then
      [[ -z $rel ]] || die "Bad selection: a dest line has a path"
      SEL_DESTS+=("$d"); continue
    fi
    bad_rel "$rel" && die "Bad selection: $d/$rel is not a plain relative path"
    p=$(realpath -e -- "$MNT/$d${rel:+/$rel}" 2>/dev/null) || die "Bad selection: $MNT/$d/$rel does not exist"
    base=$(realpath -e -- "$MNT/$d")
    [[ $p == "$base" || $p == "$base"/* ]] || die "Bad selection: $MNT/$d/$rel is outside $d"
    [[ -n ${seen["$d/$rel"]} ]] && die "Bad selection: $d/$rel is listed twice"
    seen["$d/$rel"]=1; SEL_ITEMS+=("$d"$'\t'"$rel")
    [[ -z $rel ]] && FULL_SRC[$d]=1
  done < "$RUN/selection.tsv"
  for a in "${SEL_ITEMS[@]}"; do   # no item inside another: walk each item's parents
    d=${a%%$'\t'*}; rel=${a#*$'\t'}
    while [[ -n $rel ]]; do
      if [[ $rel == */* ]]; then rel=${rel%/*}; else rel=""; fi
      [[ -n ${seen["$d/$rel"]} ]] && die "Bad selection: $d/${a#*$'\t'} is inside $d${rel:+/$rel}"
    done
  done
  (( ${#SEL_ITEMS[@]} )) || die "Bad selection: no item to move"
  (( ${#SEL_DESTS[@]} )) || die "Bad selection: no destination disk"
}
unit_conflict() {   # src dst rel -> 0 when moving rel would meet a file at the same path on dst, or a file where a folder is (or the reverse)
  local s=$MNT/$1/$3 d=$MNT/$2/$3 t p
  [[ -e $d || -L $d ]] || return 1
  while IFS= read -r -d '' p; do
    t=${p%% *}; p=${p#* }; p=$d${p:+/$p}
    [[ -e $p || -L $p ]] || continue
    [[ $t == d && -d $p && ! -L $p ]] || return 0   # a file (or link) meets anything, or a folder meets a non-folder
  done < <(find "$s" -printf '%y %P\0' 2>/dev/null)
  return 1
}
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
      printf '%s\0' "$MNT/$d/$rel"   # one unit as it is
    fi
  done > "$RUN/cand.sel"
  xargs -0 -r du -sk --null -- < "$RUN/cand.sel" 2>/dev/null | sort -z -t$'\t' -k1,1nr > "$RUN/cand.units"
}
plan_move() {   # Data Move planner: the ticked items onto the ticked disks. Writes plan.tsv; exits itself on an empty or failed plan (D5)
  local sz path d rel share r recv why bad=0 item has rhas s
  local -A planned_src   # "disk|item folder" -> source disks already planned onto that disk with that item folder
  plan_count=0; plan_kib=0; plan_skipped=0
  : > "$RUN/plan.tsv"
  read_selection
  log "Scanning the selection (depth $ITEM_DEPTH)"
  expand_units
  while IFS=$'\t' read -r -d '' sz path; do
    d=${path#"$MNT/"}; d=${d%%/*}; rel=${path#"$MNT/$d/"}; share=${rel%%/*}
    why=""
    if ! item_static_ok "$path" why; then
      log "PLAN-SKIP $(human "$sz")  $path  ($why)"; (( plan_skipped++ )); continue
    fi
    item=$(cut -d/ -f1-$(( ITEM_DEPTH + 1 )) <<< "$rel")   # the item folder (<share>/<item> at ITEM_DEPTH) this unit belongs to
    recv=""; rhas=0
    for r in "${SEL_DESTS[@]}"; do
      [[ $r == "$d" ]] && continue                     # D3: never back to its own disk
      [[ -n ${FULL_SRC[$r]} ]] && continue             # D3: never onto a disk ticked in full
      (( AVAIL[$r] - sz < MIN_FREE_KB )) && continue   # the minimum free space floor
      share_allows "$share" "$r" || continue
      has=0; [[ -e $MNT/$r/$item || -n ${planned_src["$r|$item"]} ]] && has=1   # D2: prefer the disk that already holds the item folder
      if [[ -z $recv ]] || (( has > rhas || (has == rhas && AVAIL[$r] > AVAIL[$recv]) )); then recv=$r; rhas=$has; fi   # D1: then the most room
    done
    if [[ -z $recv ]]; then
      log "PLAN-NOFIT $(human "$sz")  $path  (no ticked disk has room above the minimum free space)"; (( bad++ )); continue
    fi
    why=""   # D2: merge, never overwrite - neither a file already on the destination nor one another ticked item brings there
    if unit_conflict "$d" "$recv" "$rel"; then why="a file already exists at the same path on $recv"
    else
      for s in ${planned_src["$recv|$item"]}; do
        [[ $s == "$d" ]] && continue
        unit_conflict "$d" "$s" "$rel" && { why="$s also sends a file with the same path to $recv"; break; }
      done
    fi
    [[ -n $why ]] && { log "PLAN-CONFLICT $(human "$sz")  $path -> $recv  ($why)"; (( bad++ )); }
    planned_src["$recv|$item"]+="$d "
    (( plan_count++, plan_kib += sz ))
    printf '%s\t%s\t%s\t%s\t%s\n' "$plan_count" "$sz" "$d" "$recv" "$rel" >> "$RUN/plan.tsv"
    (( USED[$d] -= sz, AVAIL[$d] += sz, USED[$recv] += sz, AVAIL[$recv] -= sz ))
    log "PLAN $plan_count  $(human "$sz")  $path  ->  $recv"
    st_set plan_count "$plan_count" plan_kib "$plan_kib" plan_skipped "$plan_skipped"
  done < "$RUN/cand.units"
  rm -f "$RUN"/cand.*
  st_set plan_count "$plan_count" plan_kib "$plan_kib" plan_skipped "$plan_skipped"
  report "PROJECTED AFTER"
  summary="$plan_count move(s), $(human "$plan_kib") planned; $plan_skipped item(s) left out (in-progress, hardlinked or excluded share)"
  log "Plan: $summary"
  if (( bad )); then   # D5: nothing moves while any ticked item cannot be placed
    write_move_script   # the move script shows what would have moved
    die "$bad item(s) cannot be moved - they don't fit above the minimum free space or would overwrite a file. Nothing was moved; see the log"
  fi
  if (( plan_count == 0 )); then
    msg="Nothing can be moved - $plan_skipped item(s) left out (in-progress, hardlinked or excluded share), see log"
    (( plan_skipped )) || msg="Nothing to move - the ticked items hold nothing to move"
    FINAL=done; st_set state done warn 1 msg "$msg"; notify warning "$msg"; exit 0
  fi
}

############################## MAIN ##############################
case $MODE in plan|run|move-plan|move-run) ;; *) echo "usage: $0 plan|run|move-plan|move-run" >&2; exit 2 ;; esac
[[ $EUID -eq 0 || -n $RB_MNT ]] || { echo "must run as root" >&2; exit 1; }
mkdir -p "$RUN"
exec 9>"$RUN/lock"
flock -n 9 || { echo "a rebalance is already running" >&2; exit 1; }

[[ -f $LOG ]] && mv -f "$LOG" "$LOG.1"
exec >>"$LOG" 2>&1
echo $$ > "$RUN/pid"
rm -f "$RUN"/{control,progress,plan.tsv,history.tsv,start.tsv,reads.prev,moves.sh} "$RUN"/cand.*
load_cfg

on_exit() {
  restore_wm
  rm -f "$RUN/progress" "$RUN"/cand.* "$RUN/pid"
  [[ -z $FINAL ]] && st_set state error msg "Engine stopped unexpectedly - see log"
}
trap on_exit EXIT
trap 'log "ABORT requested - stopping now"; FINAL=aborted; st_set state aborted msg "Aborted by user"; exit 143' TERM INT HUP

MIN_FREE_KB=$(( MIN_FREE_GB * 1024 * 1024 ))
MAX_MOVE_KB=$(( MAX_MOVE_GB * 1024 * 1024 ))
st_set state planning mode "$MODE" pid $$ started "$EPOCHSECONDS" tol_pct "$TOLERANCE_PCT" \
  plan_count 0 plan_kib 0 plan_skipped 0 done_count 0 done_kib 0 skipped 0 cur_idx 0 turbo off msg ""
if $MOVE; then log "Data Move - mode: $MODE"; else log "Array Rebalance - mode: $MODE"; fi

grep -q '^mdState="STARTED"' "$VAR_INI" 2>/dev/null || die "Array is not started"
GLOBAL_INC=$(cfg_val shareUserInclude "$SHARE_CFG_DIR/share.cfg")
GLOBAL_EXC=$(cfg_val shareUserExclude "$SHARE_CFG_DIR/share.cfg")

read_disks
(( ${#DISKS[@]} >= 2 )) || die "Need at least two array disks to rebalance"
for d in "${DISKS[@]}"; do printf '%s\t%s\t%s\n' "$d" "${SIZE[$d]}" "${USED[$d]}"; done > "$RUN/start.tsv"

tot_size=0; tot_used=0
for d in "${DISKS[@]}"; do (( tot_size += SIZE[$d], tot_used += USED[$d] )); done
ratio_ppm=$(( tot_used * 1000000 / tot_size ))
for d in "${DISKS[@]}"; do
  TARGET[$d]=$(( SIZE[$d] * ratio_ppm / 1000000 ))
  TOL[$d]=$(( SIZE[$d] * TOLERANCE_PCT / 100 ))
done
st_set target_ppm "$ratio_ppm"
report "BEFORE"

# ---------- PLAN ----------
if $MOVE; then plan_move; else   # the rebalance planner below (simulated greedy, largest items first) runs for plan|run only
declare -A EXHAUSTED DONE PLANNED_AT NOCAND
plan_count=0; plan_kib=0; plan_skipped=0
: > "$RUN/plan.tsv"
while :; do
  donor=""; best=0
  for d in "${DISKS[@]}"; do
    [[ -n ${EXHAUSTED[$d]} ]] && continue
    ex=$(( USED[$d] - TARGET[$d] ))
    (( ex > TOL[$d] && ex > best )) && { best=$ex; donor=$d; }
  done
  [[ -z $donor ]] && break
  [[ -f $RUN/cand.$donor ]] || { log "Scanning $donor (depth $ITEM_DEPTH)"; build_candidates "$donor"; }
  [[ -s $RUN/cand.$donor ]] || NOCAND[$donor]=1   # nothing in included shares at ITEM_DEPTH

  picked=0
  while IFS=$'\t' read -r -d '' sz path; do
    [[ -n ${DONE[$path]} ]] && continue
    excess=$(( USED[$donor] - TARGET[$donor] ))
    (( excess <= TOL[$donor] )) && break
    (( sz > excess + TOL[$donor] )) && continue
    (( MAX_MOVE_KB > 0 && plan_kib + sz > MAX_MOVE_KB )) && continue
    rel=${path#"$MNT/$donor/"}; share=${rel%%/*}
    recv=""; rbest=0
    for r in "${DISKS[@]}"; do
      [[ $r == "$donor" ]] && continue
      def=$(( TARGET[$r] - USED[$r] ))
      (( def <= 0 )) && continue
      (( sz > def + TOL[$r] )) && continue
      (( AVAIL[$r] - sz < MIN_FREE_KB )) && continue
      [[ -e $MNT/$r/$rel || -n ${PLANNED_AT["$r|$rel"]} ]] && continue
      share_allows "$share" "$r" || continue
      (( def > rbest )) && { rbest=$def; recv=$r; }
    done
    [[ -z $recv ]] && continue
    DONE[$path]=1
    [[ -n $(find "$path" -type f -size +0c -print -quit 2>/dev/null) ]] || continue   # no file with data (empty folder): moving it frees nothing (#7)
    why=""
    if ! item_static_ok "$path" why; then
      log "PLAN-SKIP $(human "$sz")  $path  ($why)"; (( plan_skipped++ )); continue
    fi
    (( plan_count++, plan_kib += sz ))
    printf '%s\t%s\t%s\t%s\t%s\n' "$plan_count" "$sz" "$donor" "$recv" "$rel" >> "$RUN/plan.tsv"
    PLANNED_AT["$recv|$rel"]=1
    (( USED[$donor] -= sz, AVAIL[$donor] += sz, USED[$recv] += sz, AVAIL[$recv] -= sz ))
    log "PLAN $plan_count  $(human "$sz")  $MNT/$donor/$rel  ->  $recv"
    st_set plan_count "$plan_count" plan_kib "$plan_kib" plan_skipped "$plan_skipped"
    picked=1; break
  done < "$RUN/cand.$donor"
  (( picked )) || EXHAUSTED[$donor]=1
done
rm -f "$RUN"/cand.*
st_set plan_count "$plan_count" plan_kib "$plan_kib" plan_skipped "$plan_skipped"
report "PROJECTED AFTER"
summary="$plan_count move(s), $(human "$plan_kib") planned; $plan_skipped item(s) left out (in-progress or hardlinked)"
log "Plan: $summary"

if (( plan_count == 0 )); then   # EXHAUSTED = a disk was over tolerance but had nothing eligible
  if (( ${#EXHAUSTED[@]} && plan_skipped )); then msg="Nothing can be moved - $plan_skipped item(s) left out (in-progress or hardlinked), see log"
  elif (( ${#EXHAUSTED[@]} && ${#NOCAND[@]} == ${#EXHAUSTED[@]} )); then msg="Nothing can be moved - the over-full disk has no items in included shares"
  elif (( ${#EXHAUSTED[@]} )); then msg="Nothing can be moved - no receiving disk or size limit fits the over-full disk's items"
  else msg="Nothing to move - array is already balanced"; fi
  FINAL=done
  if (( ${#EXHAUSTED[@]} )); then st_set state done warn 1 msg "$msg"; notify warning "$msg"
  else st_set state done msg "$msg"; notify normal "$msg"; fi
  exit 0
fi
fi   # end of the rebalance planner
if [[ $MODE == plan || $MODE == move-plan ]]; then
  write_move_script
  FINAL=planned; st_set state planned msg "$summary"
  notify normal "Dry run: $summary"
  exit 0
fi

# ---------- EXECUTE ----------
st_set state running
done_count=0; done_kib=0; skipped=0; turbo_tried=0
while IFS=$'\t' read -r idx sz src dst rel; do
  check_control || break
  wait_until_clear || break
  st_set cur_idx "$idx" cur_started "$EPOCHSECONDS" cur_cmd ""
  t0=$EPOCHSECONDS; reason=""
  if   [[ ! -e $MNT/$src/$rel ]]; then reason="source no longer exists"
  elif $MOVE && unit_conflict "$src" "$dst" "$rel"; then reason="a file already exists at the same path on $dst"
  elif ! $MOVE && [[ -e $MNT/$dst/$rel ]]; then reason="already exists on $dst"
  elif (( $(df_avail "$dst") - sz < MIN_FREE_KB )); then reason="not enough free space on $dst"
  else item_live_ok "$MNT/$src/$rel" reason
  fi
  if [[ -n $reason ]]; then
    log "SKIP  $(human "$sz")  $MNT/$src/$rel  ($reason)"
    history "$idx" skip "$reason" "$sz" "$src" "$dst" "$t0" "$EPOCHSECONDS" "$rel"
    (( skipped++ )); st_set skipped "$skipped"
    continue
  fi
  (( turbo_tried++ )) || enable_turbo
  log "MOVE $idx/$plan_count  $(human "$sz")  $MNT/$src/$rel  ->  $MNT/$dst/"
  run_rsync "$src" "$dst" "$rel"; rc=$?
  rm -f "$RUN/progress"
  [[ -d $MNT/$src/$rel ]] && find "$MNT/$src/$rel" -depth -type d -empty -delete
  if (( rc != 0 )) || [[ -e $MNT/$src/$rel ]]; then
    history "$idx" fail "rsync exit $rc" "$sz" "$src" "$dst" "$t0" "$EPOCHSECONDS" "$rel"
    die "Move failed (rsync exit $rc): $MNT/$src/$rel -> $dst - stopping"
  fi
  history "$idx" done "" "$sz" "$src" "$dst" "$t0" "$EPOCHSECONDS" "$rel"
  (( done_count++, done_kib += sz ))
  st_set done_count "$done_count" done_kib "$done_kib" cur_idx 0
done < "$RUN/plan.tsv"

restore_wm
read_disks
report "AFTER"
summary="$done_count of $plan_count moved ($(human "$done_kib")), $skipped skipped"
if (( STOP_REQ )); then
  FINAL=stopped; st_set state stopped cur_idx 0 msg "Stopped by user: $summary"
  log "Stopped by user: $summary"; notify normal "Stopped: $summary"
else
  FINAL=done; st_set state done cur_idx 0 msg "$summary"
  log "Done: $summary"; notify normal "Done: $summary"
fi
