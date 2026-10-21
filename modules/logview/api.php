<?php
/**
 * Logview API — ProxyMon module
 * FILE: logview/api.php
 *
 * Reads SQUID_LOG_FILE from proxymon.env and returns parsed JSON
 *
 * Params:
 *   ?lines=N        Number of lines from end of file (default 500, max 5000)
 *   ?since=OFFSET   Byte offset to read only new lines (for polling)
 *   ?info=1         Returns only file size (for polling check)
 *   ?grep=TERM      Full-file grep search (bypasses line limit)
 */

header('Content-Type: application/json');
header('Cache-Control: no-store');

// proxymon.env is generated at install time and also read by worker.php —
// pulling SQUID_LOG_FILE from here keeps this module in sync if an install
// ever uses a non-default Squid log path.
require_once __DIR__ . '/env.php';

$proxymonEnv = readEnvFile('/etc/proxymon/proxymon.env');
define('LOG_FILE', $proxymonEnv['SQUID_LOG_FILE'] ?? throw new RuntimeException('SQUID_LOG_FILE missing in proxymon.env'));
define('MIN_LOG_LINES_REQUEST', 50);
define('MAX_LOG_LINES_REQUEST', 5000);

// Use the time zone configured in the system (same detection as worker.php,
// so Logview timestamps match the rest of the panel instead of showing UTC)
$sysTz = '';
if (is_readable('/etc/timezone')) {
    $sysTz = trim(file_get_contents('/etc/timezone'));
}
if (!$sysTz) {
    $sysTz = trim(shell_exec('timedatectl show --property=Timezone --value 2>/dev/null') ?? '');
}
if ($sysTz && @timezone_open($sysTz)) {
    date_default_timezone_set($sysTz);
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function err($msg, $code = 500) {
    http_response_code($code);
    echo json_encode(['error' => $msg]);
    exit;
}

function parse_line($line) {
    // Squid native log format:
    // timestamp elapsed client action/code bytes method url user hierarchy/from mime
    $line = trim($line);
    if ($line === '') return null;

    $parts = preg_split('/\s+/', $line, 10);
    if (count($parts) < 9) return null;

    $ts        = (float)$parts[0];
    $elapsed   = (int)$parts[1];
    $client    = $parts[2];
    $action    = $parts[3]; // e.g. TCP_HIT/200
    $bytes     = (int)$parts[4];
    $method    = $parts[5];
    $url       = $parts[6];
    $user      = $parts[7] === '-' ? '-' : $parts[7];
    $hier      = $parts[8]; // e.g. DIRECT/1.2.3.4
    $mime      = isset($parts[9]) ? $parts[9] : '-';

    // Split action code
    $cache_code = '-'; $http_code = '-';
    if (strpos($action, '/') !== false) {
        list($cache_code, $http_code) = explode('/', $action, 2);
    }

    // Format timestamp
    $dt = date('Y-m-d H:i:s', (int)$ts);

    return [
        'ts'         => $dt,
        'elapsed'    => $elapsed,
        'client'     => $client,
        'cache_code' => $cache_code,
        'http_code'  => $http_code,
        'bytes'      => $bytes,
        'method'     => $method,
        'url'        => $url,
        'user'       => $user,
        'hier'       => $hier,
        'mime'       => $mime,
    ];
}

function fmt_bytes($bytes) {
    if ($bytes >= 1048576) return round($bytes / 1048576, 1) . ' MB';
    if ($bytes >= 1024)    return round($bytes / 1024)       . ' KB';
    return $bytes . ' B';
}

// ── Check file ───────────────────────────────────────────────────────────────

if (!file_exists(LOG_FILE)) {
    error_log('Logview: log file not found: ' . LOG_FILE);
    err("Log file not found.", 404);
}
if (!is_readable(LOG_FILE)) {
    error_log('Logview: log file not readable: ' . LOG_FILE);
    err("Log file not readable. Check server permissions.");
}

$file_size = filesize(LOG_FILE);
// Identity of the file behind LOG_FILE. A mv-style rotation replaces the file,
// so the inode changes and every byte offset held by a client became stale.
$file_id = (string)fileinode(LOG_FILE);

// ── Mode: info only (polling size check) ─────────────────────────────────────

if (isset($_GET['info'])) {
    echo json_encode(['size' => $file_size]);
    exit;
}

// ── Mode: full-file grep search ───────────────────────────────────────────────

if (isset($_GET['grep']) && $_GET['grep'] !== '') {
    $term = $_GET['grep'];

    // Sanitize: only allow safe characters
    if (!preg_match('/^[\w\.\-\:\/@\s]+$/', $term)) {
        err('Invalid search term. Only alphanumeric characters, dots, dashes, colons, slashes and @ are allowed.', 400);
    }

    $escaped = escapeshellarg($term);
    $log     = escapeshellarg(LOG_FILE);
    $max_matches = 5000;
    $search_command = "timeout 20 grep -Fa -e $escaped $log 2>/dev/null | tail -n $max_matches";
    $search_command .= '; search_status=("${PIPESTATUS[@]}");'
        . ' if [ "${search_status[1]}" -ne 0 ]; then exit 200; fi;'
        . ' exit "${search_status[0]}"';
    $output_lines = [];
    exec('bash -c ' . escapeshellarg($search_command), $output_lines, $search_status);
    if ($search_status === 124) {
        err('Search exceeded the 20-second limit. No results returned.', 504);
    }
    if ($search_status === 200) {
        err('Cannot retain the latest search matches: tail failed.', 500);
    }
    if ($search_status > 1) {
        err('Cannot search the log: grep/timeout exit ' . $search_status . '.', 500);
    }
    $output = implode("\n", $output_lines);

    if ($output === null || $output === '') {
        echo json_encode([
            'rows'       => [],
            'offset'     => $file_size,
            'log_file'   => LOG_FILE,
            'total_rows' => 0,
            'grep'       => true,
        ]);
        exit;
    }

    $rows = [];
    foreach (explode("\n", $output) as $line) {
        $r = parse_line($line);
        if ($r) $rows[] = $r;
    }

    // Newest first
    $rows = array_reverse($rows);

    echo json_encode([
        'rows'       => $rows,
        'offset'     => $file_size,
        'log_file'   => LOG_FILE,
        'total_rows' => count($rows),
        'grep'       => true,
    ]);
    exit;
}

// ── Mode: poll new lines since byte offset ────────────────────────────────────

if (isset($_GET['since'])) {
    $since = max(0, (int)$_GET['since']);
    // An offset past the end means the file was rotated or truncated: the
    // bytes we were waiting for are gone and a new file started. Reporting
    // the new size alone would skip whatever the new file already holds,
    // so it is read from the beginning instead, bounded like any other read.
    if ($since > $file_size) {
        $since = 0;
        $rotated = true;
    }
    // A mv-style rotation whose new file already grew past the old offset is
    // invisible to the size check above. The identity the client carries does
    // see it: a mismatch means its offset belongs to a file no longer here.
    $client_id = isset($_GET['fileid']) ? (string)$_GET['fileid'] : '';
    if ($client_id !== $file_id) {
        $since = 0;
        $rotated = true;
    }
    if ($file_size === 0) {
        echo json_encode(['rows' => [], 'offset' => 0, 'rotated' => true, 'file_id' => $file_id]);
        exit;
    }
    $fh = fopen(LOG_FILE, 'rb');
    if ($fh === false) {
        err('Log file became unreadable.', 500);
    }
    $max_read = 5 * 1024 * 1024;
    $read_len = min($file_size - $since, $max_read);
    fseek($fh, $since);
    $new_data = $read_len > 0 ? fread($fh, $read_len) : '';
    fclose($fh);

    // Keep only complete lines — an in-progress write can leave a partial
    // line at the end, which would parse as a truncated row and be lost
    // on the next poll (it starts past this offset).
    $last_nl = strrpos($new_data, "\n");
    if ($last_nl !== false) {
        $new_data = substr($new_data, 0, $last_nl);
        $offset = $since + $last_nl + 1;
    } else {
        $new_data = '';
        $offset = $since;
    }

    $rows = [];
    foreach (explode("\n", $new_data) as $line) {
        $r = parse_line($line);
        if ($r) $rows[] = $r;
    }
    echo json_encode([
        'rows'    => $rows,
        'offset'  => $offset,
        'rotated' => isset($rotated),
        'file_id' => $file_id,
    ]);
    exit;
}

// ── Mode: initial load (last N lines) ────────────────────────────────────────

$lines_req = isset($_GET['lines']) ? (int)$_GET['lines'] : 500;
$lines_req = max(MIN_LOG_LINES_REQUEST, min(MAX_LOG_LINES_REQUEST, $lines_req));

// Read last N lines efficiently using tail-like seek
$fh = fopen(LOG_FILE, 'rb');
if ($fh === false) {
    err('Log file became unreadable.', 500);
}
$chunk    = 65536; // 64KB chunks
$pos      = $file_size;
$buf      = '';
$found    = 0;
$max_buf  = 10 * 1024 * 1024; // 10MB safety cap

while ($pos > 0 && $found < $lines_req + 1 && strlen($buf) < $max_buf) {
    $read = min($chunk, $pos);
    $pos -= $read;
    fseek($fh, $pos);
    $buf = fread($fh, $read) . $buf;
    $found = substr_count($buf, "\n");
}
fclose($fh);

// Keep only complete lines, same reason as the poll mode above: a line
// still being written must be re-read when its newline arrives.
$last_nl = strrpos($buf, "\n");
if ($last_nl !== false) {
    $initial_offset = $file_size - (strlen($buf) - $last_nl - 1);
    $buf = substr($buf, 0, $last_nl);
} else {
    $initial_offset = $file_size - strlen($buf);
    $buf = '';
}

$all_lines = explode("\n", $buf);
// Keep the last N complete lines. The partial line at the head of the buffer
// was already dropped above, so no extra slot is needed here.
$last = array_slice($all_lines, -$lines_req);

$rows = [];
foreach ($last as $line) {
    $r = parse_line($line);
    if ($r) $rows[] = $r;
}

// Return newest first
$rows = array_reverse($rows);

echo json_encode([
    'rows'      => $rows,
    'offset'    => $initial_offset,
    'log_file'  => LOG_FILE,
    'total_rows'=> count($rows),
    'file_id'   => $file_id,
]);
