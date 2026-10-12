package ReportAnalytics;
# Squidreports analytics. Distributed under the project's GPL license.
use strict;
use warnings;
use JSON::PP;
use Socket qw(inet_pton AF_INET AF_INET6);
use POSIX qw(strftime);
use Time::Local qw(timelocal);
use File::Basename qw(basename);

sub statistics_root {
    return ProxymonEnv::required($main::proxymon_settings,'REPORT_STATS_PATH');
}
sub statistics_file {
    my ($root,$date,$file) = @_;
    die "Invalid statistics path\n" unless $date =~ /^\d{8}$/
        && $file =~ /^\.(?:userstat|sitestat|mime|ext|subnet|denied)$/;
    my $dir=statistics_root($root)."/$date";
    return "$dir/$file" if -d $dir;
    return "$root/$date/$file";
}

sub host {
    my $s = lc($_[0] // '');
    $s =~ s#^[a-z][a-z0-9+.-]*://##;
    $s =~ s#[/?\#].*$##;
    $s =~ s/^.*\@//;
    if ($s =~ /^\[([^\]]+)\](?::\d+)?$/) { return $1; }
    $s =~ s/:\d+$// unless $s =~ /:.*:/;
    $s =~ s/\.$//;
    return $s || '-';
}
sub add {
    my ($r,$size,$ms,$hit,$time,$url) = @_;
    $r->{$_} //= 0 for qw(requests bytes ms hit miss hit_ms miss_ms hit_requests miss_requests);
    $r->{requests}++;
    $r->{bytes} += $size;
    $r->{ms} += $ms;
    $r->{$hit ? 'hit' : 'miss'} += $size;
    $r->{$hit ? 'hit_ms' : 'miss_ms'} += $ms;
    $r->{$hit ? 'hit_requests' : 'miss_requests'}++;
    $r->{first} = $time if !defined($r->{first}) || $time < $r->{first};
    $r->{last} = $time if !defined($r->{last}) || $time > $r->{last};
    if (!defined($r->{max}) || $size > $r->{max}) { $r->{max}=$size; $r->{url}=$url; }
}
sub accumulate {
    my ($data,$user,$client,$url,$mime,$size,$ms,$hit,$time,$hour) = @_;
    $size = 0 if $size < 0;
    $ms = 0 if $ms < 0;
    add($data->{mime}{$mime} //= {},$size,$ms,$hit,$time,$url);
    add($data->{clients}{$client}{$user} //= {},$size,$ms,$hit,$time,$url);
    add($data->{sites}{host($url)}{$user} //= {},$size,$ms,$hit,$time,$url);
    add($data->{hours}{sprintf('%02d',$hour)} //= {},$size,$ms,$hit,$time,$url);
}
sub merge {
    my ($to,$from) = @_;
    $to->{$_} += $from->{$_} // 0 for qw(requests bytes ms hit miss hit_ms miss_ms hit_requests miss_requests);
    $to->{first}=$from->{first} if defined($from->{first}) && (!defined($to->{first}) || $from->{first}<$to->{first});
    $to->{last}=$from->{last} if defined($from->{last}) && (!defined($to->{last}) || $from->{last}>$to->{last});
    if (defined($from->{max}) && (!defined($to->{max}) || $from->{max}>$to->{max})) { $to->{max}=$from->{max}; $to->{url}=$from->{url}; }
}
sub network_rules {
    my ($path,$additional) = @_;
    die "Invalid additional network configuration\n" unless ref($additional) eq 'ARRAY';
    my $settings=ref($path) eq 'HASH' ? $path : ProxymonEnv::read_env($path);
    my $range=$settings->{RANGE};
    die "RANGE missing or empty in proxymon.env\n" unless defined($range) && length($range);
    my $rules=[@$additional,[$range,$range]];
    network('0.0.0.0',$rules);
    return $rules;
}
sub network {
    my ($ip,$rules) = @_;
    my $family = index($ip,':') >= 0 ? AF_INET6 : AF_INET;
    my $packed = inet_pton($family,$ip);
    return $ip unless defined $packed;
    my @matches;
    for my $rule (@$rules) {
        die "Invalid network rule\n" unless ref($rule) eq 'ARRAY' && @$rule==2;
        my ($label,$cidr)=@$rule;
        my ($address,$bits) = split m#/#,$cidr,2;
        die "Invalid network CIDR\n" unless defined($bits) && $bits =~ /^\d+$/ && $bits <= (index($address,':')>=0 ? 128 : 32);
        my $af = index($address,':')>=0 ? AF_INET6 : AF_INET;
        my $net = inet_pton($af,$address);
        die "Invalid network address\n" unless defined($net) && defined($label) && length($label);
        next unless $af==$family;
        my $full=int($bits/8); my $part=$bits%8;
        next unless substr($packed,0,$full) eq substr($net,0,$full);
        next if $part && ((ord(substr($packed,$full,1)) ^ ord(substr($net,$full,1))) & (255 << (8-$part)));
        push @matches,[$bits,$label];
    }
    return (sort {$b->[0]<=>$a->[0]} @matches)[0][1] if @matches;
    return $ip;
}
sub domain {
    my ($host,$suffixes) = @_;
    return $host if $host =~ /:/ || $host =~ /^\d+(?:\.\d+){3}$/;
    my @parts=split /\./,$host;
    my $lookup=ref($suffixes) eq 'HASH' ? $suffixes : {map {$_=>1} @$suffixes};
    for my $n (reverse 1..$#parts) {
        my $suffix=join('.',@parts[-$n..-1]);
        return join('.',@parts[-($n+1)..-1]) if $lookup->{$suffix};
    }
    return @parts>1 ? join('.',@parts[-2,-1]) : $host;
}
sub select_days {
    my ($root,$year,$month,$day,$week)=@_;
    die "Invalid period\n" unless $year =~ /^\d{4}$/ && $year>=1970 && $year<=9998
        && ($month eq 'all' || $month =~ /^(0[1-9]|1[0-2])$/)
        && ($day eq '' || ($month ne 'all' && $day =~ /^(0[1-9]|[12]\d|3[01])$/))
        && ($week eq '' || $week =~ /^(0[1-9]|[1-4]\d|5[0-3])$/);
    if ($week ne '') {
        my $max=strftime('%V',localtime(timelocal(0,0,12,28,11,$year)));
        die "Invalid ISO week\n" if $week>$max;
    } elsif ($day ne '') { timelocal(0,0,12,$day,$month-1,$year); }
    my $prefix=$year.($month eq 'all'?'':$month).$day;
    return () unless -d $root;
    opendir my $dh,$root or die "Cannot read report directory\n";
    my @dirs=map {"$root/$_"} sort grep {/^\d{8}$/ && ($week ne '' || index($_,$prefix)==0)} readdir $dh;
    closedir $dh or die "Cannot finish reading report directory\n";
    my @out;
    for my $dir (@dirs) {
        next unless -d $dir && basename($dir) =~ /^(\d{4})(\d{2})(\d{2})$/;
        my ($y,$m,$d)=($1,$2,$3);
        my $t=eval {timelocal(0,0,12,$d,$m-1,$y)};
        next unless defined $t;
        next if $week ne '' && strftime('%G-%V',localtime($t)) ne "$year-$week";
        push @out,$dir;
    }
    return @out;
}
1;
