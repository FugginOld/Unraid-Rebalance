<?php
/* Array Rebalance - helpers shared by the endpoints */
function kv_file($f) {
  $out = [];
  if (!is_readable($f)) return $out;
  foreach (file($f, FILE_IGNORE_NEW_LINES) as $l) {
    $l = rtrim($l, "\r");
    $p = strpos($l, '=');
    if ($p === false) continue;
    $k = trim(substr($l, 0, $p));
    $v = substr($l, $p + 1);
    if (strlen($v) >= 2 && $v[0] === '"' && substr($v, -1) === '"') $v = substr($v, 1, -1);
    $out[$k] = $v;
  }
  return $out;
}
function csv($s) { return array_values(array_filter(array_map('trim', explode(',', (string)$s)), 'strlen')); }
/* a path relative to a disk: '' (the disk itself) or names joined by '/', with no empty, '.' or '..' part and no NUL, newline or tab */
function rel_ok($p) {
  if ($p === '') return true;
  if (preg_match('/[\x00\n\t]/', $p)) return false;
  foreach (explode('/', $p) as $part) if ($part === '' || $part === '.' || $part === '..') return false;
  return true;
}
