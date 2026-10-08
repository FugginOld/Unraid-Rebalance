<?php
/* Array Rebalance - Data Move: list one folder of an array disk (GET, JSON). Read-only. */
require __DIR__ . '/common.php';
$plugin = 'rebalance';
$mnt    = getenv('RB_MNT') ?: '/mnt';
$cfg    = array_merge(kv_file(__DIR__ . '/../default.cfg'), kv_file(getenv('RB_CFG') ?: "/boot/config/plugins/$plugin/$plugin.cfg"));

header('Content-Type: application/json');
header('Cache-Control: no-store');
function done($code, $out) { http_response_code($code); echo json_encode($out, JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE); exit; }

$disk = $_GET['disk'] ?? '';
$path = $_GET['path'] ?? '';
if (!is_string($disk) || !preg_match('/^disk[0-9]+$/', $disk)) done(400, ['ok' => false, 'msg' => 'Not an array disk']);
if (in_array($disk, csv($cfg['EXCLUDE_DISKS'] ?? ''), true)) done(400, ['ok' => false, 'msg' => 'Disk excluded in settings']);
if (!is_string($path) || !rel_ok($path)) done(400, ['ok' => false, 'msg' => 'Not a plain relative path']);
$root = realpath("$mnt/$disk");
$dir  = realpath($path === '' ? "$mnt/$disk" : "$mnt/$disk/$path");
if ($root === false || $dir === false || ($dir !== $root && strpos($dir, "$root/") !== 0) || !is_dir($dir)) done(400, ['ok' => false, 'msg' => 'Not a folder on this disk']);

$exc = csv($cfg['EXCLUDE_SHARES'] ?? '');
$inc = csv($cfg['INCLUDE_SHARES'] ?? '');
$du = []; $lines = [];
exec('du -k --max-depth=1 -- ' . escapeshellarg($dir) . ' 2>/dev/null', $lines);   /* one du for every child folder */
foreach ($lines as $l) { $f = explode("\t", $l, 2); if (count($f) === 2) $du[$f[1]] = (int)$f[0]; }
$entries = [];
foreach (scandir($dir) ?: [] as $name) {
  if ($name[0] === '.' || preg_match('/[\n\t]/', $name)) continue;   /* hidden, or a name the planner never lists */
  $p = "$dir/$name";
  $isDir = is_dir($p) && !is_link($p);
  $kib = $isDir ? ($du[$p] ?? 0) : (int)ceil(((@lstat($p) ?: [])['blocks'] ?? 0) / 2);   /* a file: allocated size, as du counts it */
  /* at the disk root only shares can be ticked; shares excluded by settings are shown but not tickable */
  $excluded = $path === '' && (!$isDir || in_array($name, $exc, true) || ($inc && !in_array($name, $inc, true)));
  $entries[] = ['name' => $name, 'type' => $isDir ? 'dir' : 'file', 'kib' => $kib, 'excluded' => $excluded];
}
done(200, ['ok' => true, 'entries' => $entries]);
