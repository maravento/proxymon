<?php
// SqStat integration. Original license: LICENSE-SqStat.
// FILE: logview/connections.php
error_reporting(E_ALL);
ini_set('display_errors', '0');
ini_set('log_errors', '1');
header('Cache-Control: no-store');
require_once __DIR__ . '/env.php';
require_once __DIR__ . '/sqstat.class.php';
define('SQSTAT_VERSION', '1.20');
define('SQSTAT_SHOWLEN', 100);
session_name('PROXYMON_SQSTAT');
session_start();
$ownOrigin = parse_url('http://' . ($_SERVER['HTTP_HOST'] ?? ''), PHP_URL_HOST);
$claimedOrigin = $_SERVER['HTTP_ORIGIN'] ?? $_SERVER['HTTP_REFERER'] ?? '';
$sameOrigin = $claimedOrigin === '' || parse_url($claimedOrigin, PHP_URL_HOST) === $ownOrigin;
if (($_SERVER['REQUEST_METHOD'] ?? 'GET') === 'POST' && $sameOrigin) {
    if (isset($_POST['stop'])) $_SESSION['refresh'] = 0;
    elseif (isset($_POST['refresh']) && is_numeric($_POST['refresh'])) {
        $value = (int)$_POST['refresh'];
        $_SESSION['refresh'] = $value <= 0 ? 0 : max(5, min(3600, $value));
    }
}
$current_refresh = $_SESSION['refresh'] ?? 5;
$env = readEnvFile('/etc/proxymon/proxymon.env');
$squidhost = $env['SQUID_MGR_HOST'] ?? throw new RuntimeException('SQUID_MGR_HOST missing in proxymon.env');
$squidport = (int)($env['SQUID_MGR_PORT'] ?? throw new RuntimeException('SQUID_MGR_PORT missing in proxymon.env'));
$configs = [$squidhost . ':' . $squidport];
$stat = new squidstat();
if (!$stat->connect($squidhost, $squidport)) {
    $stat->showError();
    exit;
}
$data = $stat->makeQuery($env['SQUID_MGR_PASSWD'] ?? '');
if ($data === false) {
    $stat->showError();
    exit;
}
$data['con'] = $data['con'] ?? [];
echo $stat->makeHtmlReport($data, false, $current_refresh);
