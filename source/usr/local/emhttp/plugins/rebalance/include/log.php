<?php
/* Array Rebalance - download the current run's log */
$logFile = '/var/log/rebalance.log';
header('Content-Type: text/plain; charset=utf-8');
header('Content-Disposition: attachment; filename="rebalance-' . date('Ymd-His') . '.log"');
header('Cache-Control: no-store');
if (is_readable($logFile)) readfile($logFile); else echo "No log yet.\n";
