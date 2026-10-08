<?php
/* Array Rebalance - actions (POST). The webGui validates csrf_token on every POST. */
require __DIR__ . '/common.php';
$plugin = 'rebalance';
$ctl    = getenv('RB_CTL') ?: "/usr/local/emhttp/plugins/$plugin/scripts/rebalance-ctl";
$cfgDir = getenv('RB_CFG_DIR') ?: "/boot/config/plugins/$plugin";
$run    = getenv('RB_RUN') ?: "/var/local/$plugin";
$mnt    = getenv('RB_MNT') ?: '/mnt';

header('Content-Type: application/json');
function reply($ok, $msg, $code = 200) { http_response_code($code); echo json_encode(['ok' => $ok, 'msg' => $msg]); exit; }

if ($_SERVER['REQUEST_METHOD'] !== 'POST') reply(false, 'POST required', 405);
$action = $_POST['action'] ?? '';

if ($action === 'move-plan' || $action === 'move-run') {   /* Data Move: validate the ticked items, write selection.tsv, then start below */
  $items = json_decode((string)($_POST['items'] ?? ''), true);
  $dests = json_decode((string)($_POST['dests'] ?? ''), true);
  if (!is_array($items) || !$items) reply(false, 'Tick at least one item to move', 400);
  if (!is_array($dests) || !$dests) reply(false, 'Tick at least one destination disk', 400);
  if (count($items) > 10000) reply(false, 'Too many items (over 10 000) - tick their folders instead', 400);
  $lines = []; $seen = [];
  foreach ($items as $it) {
    $d = is_array($it) ? ($it['disk'] ?? null) : null;
    $r = is_array($it) ? ($it['rel'] ?? null) : null;
    if (!is_string($d) || !is_string($r) || !preg_match('/^disk[0-9]+$/', $d) || !rel_ok($r)) reply(false, 'Bad item in the selection', 400);
    $key = $r === '' ? $d : "$d/$r";
    $root = realpath("$mnt/$d");
    $p = realpath($r === '' ? "$mnt/$d" : "$mnt/$d/$r");
    if ($root === false || $p === false || ($p !== $root && strpos($p, "$root/") !== 0)) reply(false, "$key no longer exists", 400);
    if (isset($seen[$key])) reply(false, "$key is listed twice", 400);
    $seen[$key] = true;
    $lines[] = "item\t$d\t$r";
  }
  foreach (array_keys($seen) as $key)   /* the page sends a minimal set; check again that no item is inside another */
    for ($a = $key; ($i = strrpos($a, '/')) !== false; )
      if (isset($seen[$a = substr($a, 0, $i)])) reply(false, "$key is inside $a - tick only the outer one", 400);
  foreach ($dests as $d) {
    if (!is_string($d) || !preg_match('/^disk[0-9]+$/', $d)) reply(false, 'Bad destination disk', 400);
    $lines[] = "dest\t$d";
  }
  if (!is_dir($run)) @mkdir($run, 0755, true);
  if (@file_put_contents("$run/selection.tsv.tmp", implode("\n", $lines) . "\n") === false || !@rename("$run/selection.tsv.tmp", "$run/selection.tsv"))
    reply(false, 'Could not write the selection', 500);
}

if (in_array($action, ['plan', 'run', 'move-plan', 'move-run', 'pause', 'resume', 'stop', 'abort'], true)) {
  $out = [];
  exec(escapeshellarg($ctl) . ' ' . escapeshellarg($action) . ' 2>&1', $out, $rc);
  reply($rc === 0, implode("\n", $out));
}

if ($action === 'save') {
  $ints = ['TOLERANCE_PCT' => [1, 20], 'ITEM_DEPTH' => [1, 3], 'MIN_FREE_GB' => [0, 100000],
           'MAX_MOVE_GB' => [0, 10000000], 'SKIP_RECENT_MIN' => [0, 1440], 'MAX_PAUSE_HOURS' => [1, 720]];
  $bools = ['TURBO_WRITE', 'PAUSE_ON_PARITY', 'SKIP_OPEN_FILES', 'SKIP_HARDLINKED', 'NOTIFY'];
  $lists = ['EXCLUDE_SHARES', 'INCLUDE_SHARES', 'EXCLUDE_DISKS'];
  $out = [];
  foreach ($ints as $k => [$lo, $hi]) {
    $v = trim($_POST[$k] ?? '');
    if (!ctype_digit($v) || (int)$v < $lo || (int)$v > $hi) reply(false, "$k must be a whole number from $lo to $hi", 400);
    $out[$k] = (string)(int)$v;
  }
  foreach ($bools as $k) $out[$k] = (($_POST[$k] ?? '') === 'true') ? 'true' : 'false';
  foreach ($lists as $k) {
    $v = preg_replace('/\s*,\s*/', ',', trim($_POST[$k] ?? ''));
    if (!preg_match('/^[A-Za-z0-9 ._,-]*$/', $v)) reply(false, "$k may only contain letters, digits, spaces, . _ - and commas", 400);
    $out[$k] = trim($v, ',');
  }
  $pat = trim($_POST['SKIP_PATTERNS'] ?? '');
  if (preg_match('/["$`\\\\\r\n]/', $pat)) reply(false, 'SKIP_PATTERNS may not contain quotes, $, backticks, backslashes or newlines', 400);
  $out['SKIP_PATTERNS'] = $pat;

  if (!is_dir($cfgDir)) @mkdir($cfgDir, 0755, true);
  $text = '';
  foreach ($out as $k => $v) $text .= "$k=\"$v\"\n";
  if (@file_put_contents("$cfgDir/$plugin.cfg", $text) === false) reply(false, 'Could not write settings to the flash drive', 500);
  reply(true, 'Settings saved - they apply to the next run');
}

reply(false, 'Unknown action', 400);
