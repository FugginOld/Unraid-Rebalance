<?php
/* Array Rebalance - show the dry run's move script (review only, never run) */
$file = (getenv('RB_RUN') ?: '/var/local/rebalance') . '/moves.sh';
header('Content-Type: text/plain; charset=utf-8');
header('Content-Disposition: inline; filename="rebalance-moves.sh"');
header('X-Content-Type-Options: nosniff');
header('Cache-Control: no-store');
if (is_readable($file)) readfile($file); else echo "No move script yet - run a dry run first.\n";
