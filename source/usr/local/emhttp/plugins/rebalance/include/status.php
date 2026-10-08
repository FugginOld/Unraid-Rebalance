<?php
/* Array Rebalance - status endpoint (GET, JSON). Read-only. */
$plugin     = 'rebalance';
$run        = getenv('RB_RUN') ?: "/var/local/$plugin";
$logFile    = getenv('RB_LOG') ?: "/var/log/$plugin.log";
$mnt        = getenv('RB_MNT') ?: '/mnt';
$varIni     = getenv('RB_VAR_INI') ?: '/var/local/emhttp/var.ini';
$cfgFile    = getenv('RB_CFG') ?: "/boot/config/plugins/$plugin/$plugin.cfg";
$defaultCfg = __DIR__ . '/../default.cfg';
require __DIR__ . '/common.php';

header('Content-Type: application/json');
header('Cache-Control: no-store');

function lines($f) {
  if (!is_readable($f)) return [];
  return array_values(array_filter(file($f, FILE_IGNORE_NEW_LINES), 'strlen'));
}
function pid_alive($pid) {
  $pid = trim((string)$pid);
  return $pid !== '' && ctype_digit($pid) && file_exists("/proc/$pid");
}

$st    = kv_file("$run/status");
$cfg   = array_merge(kv_file($defaultCfg), kv_file($cfgFile));
$state = $st['state'] ?? 'idle';
$alive = pid_alive(@file_get_contents("$run/pid"));
if (in_array($state, ['planning', 'running', 'paused'], true) && !$alive) $state = 'stale';

/* ---------- plan and history ---------- */
$plan = [];
foreach (lines("$run/plan.tsv") as $l) {
  $f = explode("\t", $l, 5);
  if (count($f) < 5) continue;
  $plan[(int)$f[0]] = ['idx' => (int)$f[0], 'kib' => (int)$f[1], 'src' => $f[2], 'dst' => $f[3],
                       'rel' => $f[4], 'title' => basename($f[4]), 'share' => explode('/', $f[4])[0]];
}
$history = []; $handled = []; $doneKib = 0; $doneCount = 0; $skipped = 0; $failed = 0;
foreach (lines("$run/history.tsv") as $l) {
  $f = explode("\t", $l, 9);
  if (count($f) < 9) continue;
  $h = ['idx' => (int)$f[0], 'result' => $f[1], 'reason' => $f[2], 'kib' => (int)$f[3], 'src' => $f[4],
        'dst' => $f[5], 'secs' => max(0, (int)$f[7] - (int)$f[6]), 'rel' => $f[8], 'title' => basename($f[8])];
  $history[] = $h;
  $handled[$h['idx']] = true;
  if ($h['result'] === 'done') { $doneKib += $h['kib']; $doneCount++; }
  elseif ($h['result'] === 'skip') $skipped++;
  else $failed++;
}

/* ---------- current move ---------- */
$current = null;
$curIdx  = (int)($st['cur_idx'] ?? 0);
if (in_array($state, ['running', 'paused'], true) && $curIdx && isset($plan[$curIdx]) && !isset($handled[$curIdx])) {
  $current = $plan[$curIdx] + ['started' => (int)($st['cur_started'] ?? 0), 'bytes' => 0, 'pct' => 0,
                               'rate' => 0, 'file' => null, 'cmd' => $st['cur_cmd'] ?? ''];
  $pr = trim((string)@file_get_contents("$run/progress"));
  if ($pr !== '') {
    $p = array_pad(preg_split('/\s+/', $pr), 5, '0');
    $mult = ['B' => 1, 'kB' => 1024, 'MB' => 1048576, 'GB' => 1073741824, 'TB' => 1099511627776][$p[3]] ?? 1;
    $current['bytes'] = (int)$p[0];
    $current['pct']   = (int)$p[1];
    $current['rate']  = (float)$p[2] * $mult;
  }
  /* file rsync is reading right now: the sender holds it open under the source disk */
  $pids = [];
  exec("pgrep -f -- 'remove-source-files --relative' 2>/dev/null", $pids);
  $prefix = "$mnt/{$current['src']}/";
  foreach ($pids as $pid) {
    foreach (glob("/proc/$pid/fd/*") ?: [] as $fd) {
      $t = @readlink($fd);
      if ($t && strpos($t, $prefix) === 0 && is_file($t)) { $current['file'] = substr($t, strlen($prefix)); break 2; }
    }
  }
}

/* ---------- queue ---------- */
$queue = []; $queueKib = 0; $queueCount = 0;
foreach ($plan as $i => $p) {
  if (isset($handled[$i]) || ($current && $i === $curIdx)) continue;
  $queueCount++; $queueKib += $p['kib'];
  if (count($queue) < 6) $queue[] = $p;
}

/* ---------- disks (live df) ---------- */
$excluded = csv($cfg['EXCLUDE_DISKS'] ?? '');
$mounts = [];
foreach (lines('/proc/mounts') as $m) { $f = explode(' ', $m); if (isset($f[1])) $mounts[$f[1]] = true; }
$paths = [];
foreach (glob("$mnt/disk[0-9]*", GLOB_ONLYDIR) ?: [] as $p) if (getenv('RB_MNT') || isset($mounts[$p])) $paths[] = $p;
natsort($paths);
$start = [];
foreach (lines("$run/start.tsv") as $l) { $f = explode("\t", $l); if (count($f) >= 3) $start[$f[0]] = (int)$f[2]; }
$disks = [];
if ($paths) {
  $out = [];
  exec('df -k --output=target,size,used,avail ' . implode(' ', array_map('escapeshellarg', $paths)) . ' 2>/dev/null', $out);
  $byPath = [];
  foreach (array_slice($out, 1) as $row) {
    $f = preg_split('/\s+/', trim($row));
    if (count($f) >= 4) $byPath[$f[0]] = [(int)$f[1], (int)$f[2], (int)$f[3]];
  }
  foreach ($paths as $p) {
    if (!isset($byPath[$p])) continue;
    $name = basename($p);
    [$size, $used, $avail] = $byPath[$p];
    $disks[] = ['name' => $name, 'size' => $size, 'used' => $used, 'avail' => $avail,
                'start_used' => $start[$name] ?? null, 'excluded' => in_array($name, $excluded, true)];
  }
}
if (isset($st['target_ppm']) && in_array($state, ['planning', 'planned', 'running', 'paused', 'stale'], true)) {
  $targetPct = (int)$st['target_ppm'] / 10000;
} else {
  $ts = 0; $tu = 0;
  foreach ($disks as $d) if (!$d['excluded']) { $ts += $d['size']; $tu += $d['used']; }
  $targetPct = $ts ? $tu * 100 / $ts : 0;
}

/* ---------- array / services ---------- */
$var    = @parse_ini_file($varIni) ?: [];
$mover  = pid_alive(@file_get_contents('/var/run/mover.pid'));
$docker = pid_alive(@file_get_contents('/var/run/dockerd.pid'));
$wm     = (string)($var['md_write_method'] ?? '');
$observed = null;
if ($current) {  /* reconstruct write reads every data disk; read/modify/write reads only target + parity */
  $md = []; $reads = [];
  exec('/usr/local/sbin/mdcmd status 2>/dev/null', $md);
  foreach ($md as $l) if (preg_match('/^rdevReads\.(\d+)=(\d+)/', $l, $m)) $reads[(int)$m[1]] = (float)$m[2];
  $prevFile = "$run/reads.prev";
  $prev = json_decode((string)@file_get_contents($prevFile), true);
  @file_put_contents($prevFile, json_encode(['t' => microtime(true), 'r' => $reads]));
  if ($reads && is_array($prev) && isset($prev['r']) && microtime(true) - $prev['t'] < 60) {
    $assigned = 0; $active = 0;
    foreach ($reads as $slot => $v) {
      if ($slot < 1 || $slot > 28 || $v <= 0 || !isset($prev['r'][$slot])) continue;
      $assigned++;
      if ($v - $prev['r'][$slot] > 0) $active++;
    }
    if ($assigned >= 3) $observed = $active >= $assigned - 1 ? 'reconstruct' : ($active <= 3 ? 'read/modify/write' : 'mixed');
  }
}

/* ---------- log tail ---------- */
$log = [];
if (is_readable($logFile)) exec('tail -n 14 ' . escapeshellarg($logFile), $log);

echo json_encode([
  'now'        => time(),
  'state'      => $state,
  'mode'       => $st['mode'] ?? null,
  'msg'        => $st['msg'] ?? '',
  'warn'       => ($st['warn'] ?? '') === '1',
  'pause_reason' => $st['pause_reason'] ?? '',
  'paused_s'   => (int)($st['paused_s'] ?? 0) + ($state === 'paused' && !empty($st['paused_since']) ? max(0, time() - (int)$st['paused_since']) : 0),
  'request'    => $alive && in_array($req = trim((string)@file_get_contents("$run/control")), ['pause', 'stop'], true) ? $req : '',
  'started'    => isset($st['started']) ? (int)$st['started'] : null,
  'updated'    => isset($st['updated']) ? (int)$st['updated'] : null,
  'turbo'      => $st['turbo'] ?? 'off',
  'target_pct' => $targetPct,
  'tol_pct'    => (float)($st['tol_pct'] ?? ($cfg['TOLERANCE_PCT'] ?? 1)),
  'plan'       => ['count' => count($plan), 'kib' => array_sum(array_column($plan, 'kib')),
                   'left_out' => (int)($st['plan_skipped'] ?? 0)],
  'done'       => ['count' => $doneCount, 'kib' => $doneKib, 'skipped' => $skipped, 'failed' => $failed],
  'current'    => $current,
  'queue'      => $queue,
  'queue_count'=> $queueCount,
  'queue_kib'  => $queueKib,
  'history'    => array_slice(array_reverse($history), 0, 6),
  'disks'      => $disks,
  'array'      => ['state' => $var['mdState'] ?? 'unknown', 'parity' => ($var['mdResyncPos'] ?? '0') !== '0',
                   'mover' => $mover, 'docker' => $docker, 'write_method' => $wm, 'observed' => $observed],
  'cfg'        => $cfg,
  'log'        => $log,
], JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE);
