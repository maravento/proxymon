<?php
function readEnvFile(string $path): array {
    $vars = [];
    if (!is_readable($path)) return $vars;
    foreach (file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        $line = trim($line);
        if ($line === '' || $line[0] === '#' || !str_contains($line, '=')) continue;
        [$key, $val] = explode('=', $line, 2);
        $val = trim($val);
        // Strip matching surrounding quotes, e.g. KEY="value" or KEY='value'
        if (strlen($val) >= 2) {
            $first = $val[0];
            $last  = $val[strlen($val) - 1];
            if (($first === '"' && $last === '"') || ($first === "'" && $last === "'")) {
                $val = substr($val, 1, -1);
            }
        }
        // Expand $VAR / ${VAR} references against keys already parsed above,
        // the same way bash resolves them when this file is sourced by
        // bandata.sh or the installer (e.g. SQUID_LOG_FILE=$SQUID_LOG_DIR/access.log).
        $val = preg_replace_callback(
            '/\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/',
            function ($m) use (&$vars) {
                $name = $m[1] !== '' ? $m[1] : $m[2];
                return $vars[$name] ?? $m[0];
            },
            $val
        );
        $vars[trim($key)] = $val;
    }
    return $vars;
}

