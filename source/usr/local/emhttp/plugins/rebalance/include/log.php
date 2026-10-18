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
