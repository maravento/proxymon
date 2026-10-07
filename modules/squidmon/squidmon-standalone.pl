#!/usr/bin/perl
# squidmon-standalone.pl
# Pure Perl implementation without Webmin dependencies
# Replaces web-lib.pl and ui-lib.pl

use strict;
use warnings;
use URI::URL;
use Cwd;

our %config;
our %text;
our %in;
our $module_name = 'squidmon';

# ============================================================
# Configuration and Initialization
# ============================================================

sub init_config {
    # Initialize global configuration
    %config = ();
    return 1;
}

# ============================================================
# Parse GET/POST Parameters
# ============================================================

sub ReadParse {
    my $query_string = '';

    if (($ENV{'REQUEST_METHOD'} // '') eq 'POST') {
        my $cl = $ENV{'CONTENT_LENGTH'} || 0;
        if ($cl > 1_048_576) {
            print "Status: 413 Payload Too Large\n\n";
            exit;
        }
        read(STDIN, $query_string, $cl) if $cl;
    } else {
        $query_string = $ENV{'QUERY_STRING'} || '';
    }

    %in = ();
    foreach my $pair (split(/&/, $query_string)) {
        my ($name, $value) = split(/=/, $pair, 2);
        next unless $name;
        $value //= '';

        # URL decode
        $name =~ tr/+/ /;
        $name =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
        $value =~ tr/+/ /;
        $value =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;

        if (exists $in{$name}) {
            # Handle multiple values
            if (ref($in{$name}) eq 'ARRAY') {
                push @{$in{$name}}, $value;
            } else {
                $in{$name} = [$in{$name}, $value];
            }
        } else {
            $in{$name} = $value;
        }
    }

    return 1;
}

# ============================================================
# Read Configuration Files
# ============================================================

sub read_file {
    my ($file, $config_ref) = @_;
    return 0 unless -f $file;

    %$config_ref = ();
    open(my $fh, '<', $file) or return 0;

    while (<$fh>) {
        chomp;
        next if /^#/ || /^\s*$/;

        if (/^([^=]+)=(.*)$/) {
            my ($key, $value) = ($1, $2);
            $key =~ s/^\s+|\s+$//g;
            $value =~ s/^\s+|\s+$//g;
            $config_ref->{$key} = $value;
        }
    }
    close($fh);
    return 1;
}

# ============================================================
# Module Configuration
# ============================================================

# Single source for the module settings. Every CGI loads them through
# load_config(), so the file path and the factory values are declared
# here and nowhere else.
our $config_file = '/var/www/proxymon/squidmon/etc/config';

our %config_defaults = (
    'squid_log'        => '/var/log/squid/access.log',
    'max_lines'        => 50000,
    'time_range'       => 24,
    'auto_refresh'     => 0,
    'refresh_interval' => 60,
    'acl_list'         =>
        "/etc/acl/squid/blocktlds.txt=Blocked TLD\n" .
        "/etc/acl/squid/blockdomains.txt=Blocked Sites\n" .
        "regex:^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}(:\\d+)?=Block IPv4\n" .
        "regex:(adlinkfly|announce\\.php\\?passkey=|info_hash|iptv|jndi:|mtc[0-9]|\\.onion|peer_id=|porn|psiphon|torrent|ultrasurf)=Blocked Patterns",
);

# Read the live configuration and fill in whatever it does not define.
# The file keeps the ACL list on one line, with \n written literally, so
# it is expanded back into real newlines here.
sub load_config {
    %config = ();
    read_file($config_file, \%config);
    foreach my $key (keys %config_defaults) {
        next if defined $config{$key} && $config{$key} ne '';
        $config{$key} = $config_defaults{$key};
    }
    $config{'acl_list'} =~ s/\\n/\n/g;
    return 1;
}

# Quote a value for use inside a single-quoted JavaScript string.
sub js_quote {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ s/\\/\\\\/g;
    $str =~ s/'/\\'/g;
    $str =~ s/\r?\n/\\n/g;
    $str =~ s{</}{<\\/}g;
    return $str;
}

# ============================================================
# Language Support
# ============================================================

sub load_language {
    my ($module) = @_;
    $module ||= $module_name;

    %text = ();

    # Determine language from environment or default to 'en'
    my $lang = $ENV{'LANG'} || 'en';
    $lang =~ s/_.+//;  # Remove encoding suffix
    $lang = 'en' unless $lang;

    # Try to load language file
    my $lang_file = "./lang/$lang";
    if (-f $lang_file) {
        open(my $fh, '<', $lang_file) or return 0;
        while (<$fh>) {
            chomp;
            next if /^#/ || /^\s*$/;
            if (/^([^=]+)=(.*)$/) {
                my ($key, $value) = ($1, $2);
                $key =~ s/^\s+|\s+$//g;
                $value =~ s/^\s+|\s+$//g;
                $text{$key} = $value;
            }
        }
        close($fh);
    }

    return 1;
}

# ============================================================
# HTML Output Functions
# ============================================================

sub ui_print_header {
    my ($title1, $title2, $title3, $help, $nomodule, $nowebmin) = @_;

    my $title = $title2 || $title1 || 'Squidmon';

    print "Content-Type: text/html; charset=utf-8\n";
    print "Cache-Control: no-cache, no-store, must-revalidate\n";
    print "Pragma: no-cache\n";
    print "\n";

    print <<'EOF';
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Proxy Monitor</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            background: #f5f7fa;
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            padding: 0;
            margin: 0;
        }
        .container { max-width: 1400px; margin: 0 auto; padding: 20px; }
        h1 { color: #333; margin-bottom: 20px; }
    </style>
</head>
<body>
    <div class="container">
EOF

    print "<h1>$title</h1>\n";

    return 1;
}

sub ui_print_footer {
    my ($home_url, $home_title) = @_;

    $home_url ||= '/';
    $home_title ||= 'Home';

    print <<'EOF';
    </div>
</body>
</html>
EOF

    return 1;
}

# ============================================================
# Utility Functions
# ============================================================

sub escape_html {
    my ($text) = @_;
    return '' unless defined $text;
    $text =~ s/&/&amp;/g;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    $text =~ s/"/&quot;/g;
    $text =~ s/'/&#39;/g;
    return $text;
}

sub format_number {
    my ($num) = @_;
    return 0 unless defined $num;
    $num =~ s/(\d)(?=(\d{3})+(?!\d))/$1,/g;
    return $num;
}

# ============================================================
# Return 1 to indicate successful module load
# ============================================================

1;
