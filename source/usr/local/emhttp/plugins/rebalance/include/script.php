<?php
/* Array Rebalance - show a move script, review only, never run: the dry run's, or with ?run=<id> an archived run's */
require __DIR__ . '/common.php';
$file = (getenv('RB_RUN') ?: '/var/local/rebalance') . '/moves.sh';
header('Content-Type: text/plain; charset=utf-8');
header('Content-Disposition: inline; filename="rebalance-moves.sh"');
header('X-Content-Type-Options: nosniff');
header('Cache-Control: no-store');
if (isset($_GET['run'])) {
  if (!run_id_ok($_GET['run'])) { http_response_code(400); echo "Bad run id\n"; exit; }
  $f = (getenv('RB_HIST') ?: '/boot/config/plugins/rebalance/history') . "/{$_GET['run']}/moves.sh";
  if (is_readable($f)) readfile($f); else echo "No move script for this run - it stopped before a plan was made.\n";
  exit;
}
if (is_readable($file)) readfile($file); else echo "No move script yet - run a dry run first.\n";
