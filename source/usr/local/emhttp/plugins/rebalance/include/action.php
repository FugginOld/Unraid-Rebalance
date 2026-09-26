<?php
/* Array Rebalance - actions (POST). The webGui validates csrf_token on every POST. */
$plugin = 'rebalance';
$ctl    = "/usr/local/emhttp/plugins/$plugin/scripts/rebalance-ctl";
$cfgDir = getenv('RB_CFG_DIR') ?: "/boot/config/plugins/$plugin";

header('Content-Type: application/json');
function reply($ok, $msg, $code = 200) { http_response_code($code); echo json_encode(['ok' => $ok, 'msg' => $msg]); exit; }

if ($_SERVER['REQUEST_METHOD'] !== 'POST') reply(false, 'POST required', 405);
$action = $_POST['action'] ?? '';

if (in_array($action, ['plan', 'run', 'pause', 'resume', 'stop', 'abort'], true)) {
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
