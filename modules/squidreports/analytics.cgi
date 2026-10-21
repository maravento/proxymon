#!/usr/bin/perl
# Squidreports - analytics
# FILE: squidreports/analytics.cgi
# Historical analytics integrated in Squidreports. Distributed under the project's GPL license.
use strict;
use warnings;
use File::Basename qw(dirname basename);
use lib dirname(__FILE__);
use CGI qw(escapeHTML escape);
use JSON::XS ();
use POSIX qw(strftime);
use Time::Local qw(timelocal);
our ($reportpath,$analytics_networks,$analytics_domain_suffixes);
require 'squidreports.cfg';
require "paths.pl";
require 'ReportAnalytics.pm';

my $q=CGI->new;
my %p=map { $_ => scalar($q->param($_) // '') } qw(year month day week period view network domain site user metric page);
$p{year} ||= (localtime)[5]+1900;
$p{month} ||= 'all';
$p{view} ||= 'series';
$p{metric} ||= 'bytes';
$p{period} ||= $p{week} ne '' ? 'week' : $p{day} ne '' ? 'day' : $p{month} ne 'all' ? 'month' : 'year';
print "Content-Type: text/html; charset=UTF-8\nCache-Control: no-store\n\n";
sub h { return escapeHTML($_[0] // ''); }
sub fail { print '<p role="alert">'.h($_[0]).'</p>'; exit; }
fail('Invalid view') unless $p{view} =~ /^(series|mime|networks|domains|sites|denied)$/;
fail('Invalid metric') unless $p{metric} =~ /^(bytes|requests|hit|miss|throughput|hit_rate|miss_rate|denied)$/;
fail('Invalid period') unless $p{period} =~ /^(day|week|month|year)$/;
$p{month}='all' if $p{period} eq 'year' || $p{period} eq 'week';
$p{day}='' unless $p{period} eq 'day';
$p{week}='' unless $p{period} eq 'week';
fail('Select a month') if $p{period} =~ /^(day|month)$/ && $p{month} eq 'all';
fail('Select a day') if $p{period} eq 'day' && $p{day} eq '';
fail('Select an ISO week') if $p{period} eq 'week' && $p{week} eq '';
fail('Invalid page') if $p{page} ne '' && ($p{page} !~ /^\d{1,8}$/ || $p{page}<1);
$p{page} ||= 1;
$p{metric}='denied' if $p{view} eq 'denied';
$p{metric}='requests' if $p{metric} eq 'denied' && $p{view} !~ /^(series|denied)$/;
for (qw(month day week)) { $p{$_}=sprintf('%02d',$p{$_}) if $p{$_} =~ /^\d{1,2}$/; }
for (qw(network domain site user)) { fail('Invalid filter') if length($p{$_})>512 || $p{$_} =~ /[\x00-\x1f]/; }
my %dates;
my $valid=eval {
    for my $root ($reportpath,ReportAnalytics::statistics_root($reportpath)) {
        $dates{basename($_)}=1 for ReportAnalytics::select_days($root,@p{qw(year month day week)});
    }
    1;
};
fail('Invalid calendar date or ISO week') unless $valid;
my $rules=$analytics_networks // [];
my $extra_suffixes=$analytics_domain_suffixes // [];
fail('Invalid analytics configuration') unless ref($rules) eq 'ARRAY' && ref($extra_suffixes) eq 'ARRAY';
$valid=eval {$rules=ReportAnalytics::network_rules($main::proxymon_settings,$rules); 1};
fail($@ || 'Invalid network configuration') unless $valid;
my @suffixes;
open my $sf,'<',dirname(__FILE__).'/domain-suffixes.txt' or fail('Cannot read domain suffixes');
while (<$sf>) { chomp; push @suffixes,$_ if $_ ne '' && !/^#/; }
close $sf or fail('Cannot finish reading domain suffixes');
for (@$extra_suffixes) { fail('Invalid domain suffix') unless defined && /^[a-z0-9-]+(?:\.[a-z0-9-]+)*$/; push @suffixes,$_; }
my %suffix_lookup=map {$_=>1} @suffixes;
sub link_to {
    my (%change)=@_;
    my %args=(%p,%change);
    return 'analytics.cgi?'.join('&amp;',map {escape($_).'='.escape($args{$_})} grep {$args{$_} ne ''} sort keys %args);
}
sub view_link { return link_to(view=>$_[0],network=>'',domain=>'',site=>'',user=>'',page=>1); }
sub read_lines {
    my ($path)=@_;
    open my $fh,'<',$path or fail('Cannot read selected report');
    my @lines=<$fh>;
    close $fh or fail('Cannot finish reading selected report');
    return @lines;
}
sub check_row {
    my ($r)=@_;
    die "Invalid metrics" unless ref($r) eq 'HASH';
    $r->{$_} //= 0 for qw(hit miss hit_ms miss_ms hit_requests miss_requests);
    for (qw(requests bytes ms hit miss hit_ms miss_ms hit_requests miss_requests first last max)) {
        die "Invalid metrics" unless defined($r->{$_}) && !ref($r->{$_}) && $r->{$_} =~ /^\d+(?:\.\d+)?$/;
    }
    die "Invalid object URL" unless defined($r->{url}) && !ref($r->{url});
}
sub read_data {
    my ($path)=@_;
    my $raw=join('',read_lines($path));
    my $x=eval {JSON::XS->new->decode($raw)};
    fail('Invalid analytics data; regenerate the selected date') unless ref($x) eq 'HASH' && ($x->{version}//0)==1 && ref($x->{data}) eq 'HASH';
    my $d=$x->{data};
    my $ok=eval {
        for my $group (qw(mime hours clients sites)) {
            die "Invalid metrics" unless ref($d->{$group}) eq 'HASH';
            for my $key (keys %{$d->{$group}//{}}) {
                if ($group eq 'mime' || $group eq 'hours') { check_row($d->{$group}{$key}); }
                else {
                    die "Invalid metrics" unless ref($d->{$group}{$key}) eq 'HASH';
                    check_row($_) for values %{$d->{$group}{$key}};
                }
            }
        }
        1;
    };
    fail('Invalid analytics metrics; regenerate the selected date') unless $ok;
    return $d;
}
sub rate { my ($r,$bytes,$ms)=@_; return ($r->{$ms}//0)>0 ? 1000*($r->{$bytes}//0)/$r->{$ms} : undef; }
sub value {
    my ($r)=@_;
    return rate($r,'bytes','ms') if $p{metric} eq 'throughput';
    return rate($r,'hit','hit_ms') if $p{metric} eq 'hit_rate';
    return rate($r,'miss','miss_ms') if $p{metric} eq 'miss_rate';
    return $r->{$p{metric}} // 0;
}
sub fmtbytes {
    my ($n)=@_; return '—' unless defined $n;
    for my $unit (qw(B KiB MiB GiB TiB)) { return sprintf('%.2f %s',$n,$unit) if $n<1024 || $unit eq 'TiB'; $n/=1024; }
}
sub fmtrate { my $n=rate(@_); return defined($n) ? fmtbytes($n).'/s' : '—'; }
sub stamp { return defined($_[0]) ? strftime('%Y-%m-%d %H:%M:%S',localtime($_[0])) : '—'; }
sub duration { my $ms=int($_[0]//0); my $s=int($ms/1000); return sprintf('%d:%02d:%02d.%03d',int($s/3600),int($s/60)%60,$s%60,$ms%1000); }
my (%rows,%original,%denied_users,@missing);
for my $date (sort keys %dates) {
    my $originalfile="$reportpath/$date/.total";
    if (-f $originalfile) {
        my @lines=read_lines($originalfile); splice @lines,0,2;
        for (@lines) {
            my ($who,$size,$hits)=split;
            fail('Invalid original report') unless defined($hits) && $size =~ /^\d+$/ && $hits =~ /^\d+$/;
            $original{$who}{bytes}+=$size; $original{$who}{requests}+=$hits;
        }
    }
    my $stats=ReportAnalytics::statistics_root($reportpath)."/$date/analyzer.json";
    my $data=-f $stats ? read_data($stats) : {};
    push @missing,$date if -f $originalfile && !-f $stats;
    if ($p{view} eq 'series') {
        for my $hour (sort keys %{$data->{hours}//{}}) {
            my $bucket=$p{period} eq 'day' ? "$hour:00" : $p{period} eq 'year' ? substr($date,0,6) : $date;
            ReportAnalytics::merge($rows{$bucket}//={},$data->{hours}{$hour});
        }
    } elsif ($p{view} eq 'mime') {
        ReportAnalytics::merge($rows{$_}//={},$data->{mime}{$_}) for keys %{$data->{mime}//{}};
    } elsif ($p{view} eq 'networks') {
        for my $ip (keys %{$data->{clients}//{}}) {
            my $network=ReportAnalytics::network($ip,$rules);
            next if $p{network} ne '' && $network ne $p{network};
            for my $who (keys %{$data->{clients}{$ip}}) {
                my $key=$p{network} eq '' ? $network : $who;
                ReportAnalytics::merge($rows{$key}//={},$data->{clients}{$ip}{$who});
            }
        }
    } elsif ($p{view} eq 'domains' || $p{view} eq 'sites') {
        for my $site (keys %{$data->{sites}//{}}) {
            my $domain=ReportAnalytics::domain($site,\%suffix_lookup);
            next if $p{domain} ne '' && $domain ne $p{domain};
            next if $p{site} ne '' && $site ne $p{site};
            for my $who (keys %{$data->{sites}{$site}}) {
                next if $p{user} ne '' && $who ne $p{user};
                my $key=$p{view} eq 'domains' ? $domain : $p{site} ne '' ? $who : $site;
                ReportAnalytics::merge($rows{$key}//={},$data->{sites}{$site}{$who});
            }
        }
    }
    my $deniedfile=ReportAnalytics::statistics_file($reportpath,$date,'.denied');
    next unless -f $deniedfile;
    for (read_lines($deniedfile)) {
        chomp;
        my ($who,$time,$code,$url)=split /\t/,$_,4;
        next unless defined $url;
        fail('Invalid denial time') unless $time =~ /^(\d\d):([0-5]\d):([0-5]\d)$/ && $1<24;
        my $hour=$1;
        if ($p{view} eq 'series') {
            my $bucket=$p{period} eq 'day' ? "$hour:00" : $p{period} eq 'year' ? substr($date,0,6) : $date;
            $rows{$bucket}{denied}++;
        }
        next unless $p{view} eq 'denied' && ($p{user} eq '' || $p{user} eq $who);
        my $host=ReportAnalytics::host($url);
        my $r=$rows{$host}//={};
        my ($y,$m,$d)=$date =~ /^(\d{4})(\d{2})(\d{2})$/;
        my ($hh,$mm,$ss)=split /:/,$time;
        my $epoch=timelocal($ss,$mm,$hh,$d,$m-1,$y);
        $r->{requests}++; $r->{denied}++; $r->{codes}{$code}++;
        $r->{first}=$epoch if !defined($r->{first}) || $epoch<$r->{first};
        $r->{last}=$epoch if !defined($r->{last}) || $epoch>$r->{last};
        $denied_users{$host}{$who}=1;
    }
}
my %titles=(series=>'History',mime=>'MIME',networks=>'Networks',domains=>'Domains',sites=>'Sites',denied=>'Denied');
my $period=$p{period} eq 'week' ? "$p{year}-W$p{week}" : $p{year}.($p{month} ne 'all'?"-$p{month}":'').($p{day} ne ''?"-$p{day}":'');
print '<!doctype html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Squidreports · Analyze</title><link rel="stylesheet" href="analytics.css"></head><body><main><h1>Squidreports · Analyze</h1><nav aria-label="Reports"><a href="index.cgi?year='.$p{year}.'&amp;month='.$p{month}.'">Back to Reports</a>';
my $detail='detailed.cgi?year='.$p{year}.'&amp;month='.$p{month}.($p{day} ne ''?'&amp;day='.$p{day}:'').($p{week} ne ''?'&amp;week='.$p{week}:'');
print '<a href="'.$detail.'">Detail</a>';
print '<a'.($p{view} eq $_?' aria-current="page"':'').' href="'.view_link($_).'">'.$titles{$_}.'</a>' for qw(series mime networks domains sites denied);
print '<button type="button" onclick="window.print()">Print</button></nav><form method="get"><label>Period <select name="period">';
print '<option'.($p{period} eq $_?' selected':'').' value="'.$_.'">'.ucfirst($_).'</option>' for qw(day week month year);
print '</select></label>';
for my $spec ([year=>1970,9998],[month=>1,12],[day=>1,31],[week=>1,53]) {
    my ($name,$min,$max)=@$spec;
    my $value=$p{$name} eq 'all'?'':$p{$name};
    print '<label>'.ucfirst($name).'<input type="number" name="'.$name.'" min="'.$min.'" max="'.$max.'" value="'.h($value).'"></label>';
}
for my $name (qw(view network domain site user)) {
    print '<input type="hidden" name="'.$name.'" value="'.h($p{$name}).'">' if $p{$name} ne '';
}
print '<label>Chart <select name="metric">';
my %metrics=(bytes=>'Bytes',requests=>'Requests',hit=>'HIT bytes',miss=>'MISS bytes',throughput=>'Throughput',hit_rate=>'HIT throughput',miss_rate=>'MISS throughput',denied=>'Denied');
print '<option'.($p{metric} eq $_?' selected':'').' value="'.$_.'">'.$metrics{$_}.'</option>' for qw(bytes requests hit miss throughput hit_rate miss_rate denied);
print '</select></label><button>Apply</button></form><p>Use the selected period fields. Week uses ISO week numbering and ISO week-year.</p><h2>'.$titles{$p{view}}.' · '.h($period).'</h2>';
for (qw(network domain site user)) { print '<p>'.ucfirst($_).': <strong>'.h($p{$_}).'</strong></p>' if $p{$_} ne ''; }
print '<details class="notice"><summary>Incomplete statistics: '.scalar(@missing).' '.(@missing == 1 ? 'day' : 'days').' missing.</summary><p>Missing dates: '.h(join(', ', map { substr($_,0,4)."-".substr($_,4,2)."-".substr($_,6,2) } @missing)).'.</p><p>Results cover available metrics only. Regenerate these dates from retained Squid logs.</p></details>' if @missing;
print '<p class="notice">Domain grouping uses the historical SquidAnalyzer suffix list and configured additions. It is not a current Public Suffix List.</p>' if $p{view} eq 'domains';
if ($p{view} eq 'series') {
    my ($bytes,$requests)=(0,0);
    for (values %original) { $bytes+=$_->{bytes}; $requests+=$_->{requests}; }
    print '<p class="summary">Original reports: '.fmtbytes($bytes).' · '.$requests.' requests · '.scalar(keys %original).' users/IPs.</p>';
}
my @keys=$p{view} eq 'series' ? sort keys %rows : sort {
    my $av=$p{view} eq 'denied' ? $rows{$a}{requests} : value($rows{$a});
    my $bv=$p{view} eq 'denied' ? $rows{$b}{requests} : value($rows{$b});
    defined($bv)<=>defined($av) || ($bv//0)<=>($av//0) || $a cmp $b;
} keys %rows;
my @chart=@keys;
@chart=sort {
    my $av=value($rows{$a});
    my $bv=value($rows{$b});
    defined($bv)<=>defined($av) || ($bv//0)<=>($av//0) || $a cmp $b;
} @chart if $p{view} eq 'series';
splice @chart,20 if $p{view} ne 'series' && @chart>20;
my $max=0;
for (@chart) { my $v=value($rows{$_}); $max=$v if defined($v) && $v>$max; }
if (@chart) {
    my $label_chars=1;
    for my $key (@chart) {
        $label_chars=length($key) if length($key)>$label_chars;
    }
    print '<div class="chart" role="group" aria-label="'.h($metrics{$p{metric}}).' by '.h($titles{$p{view}}).'" style="--label-width:'.$label_chars.'ch">';
    for my $key (@chart) {
        my $v=value($rows{$key});
        my $width=defined($v)&&$max>0 ? 100*$v/$max : 0;
        my $display=!defined($v)?'—':$p{metric}=~/rate|throughput/ ? fmtbytes($v).'/s':$p{metric}=~/bytes|hit|miss/ ? fmtbytes($v):sprintf('%.0f',$v);
        print '<span class="chart-label">'.h($key).'</span><span class="chart-track" aria-hidden="true"><span class="chart-bar" style="width:'.sprintf('%.2f',$width).'%"></span></span><span class="chart-value">'.h($display).'</span>';
    }
    print '</div><p>Chart: '.h($metrics{$p{metric}}).'.'.($p{view} ne 'series'?' First 20 rows; the table includes all rows.':'').'</p>';
} else { print '<p>No data for this selection.</p>'; }
my @full_heads=$p{view} eq 'denied' ? ('Destination','Denied','Users','Codes','First access','Last access') : ('Interval / item','Requests','Bytes','HIT bytes','MISS bytes','HIT requests','MISS requests','Duration','Throughput','HIT throughput','MISS throughput','First access','Last access','Largest object');
my @heads=$p{view} eq 'denied' ? ('Destination','Denied','Users','Codes','First','Last') : ('Item','Requests','Bytes','HIT','MISS','HIT req.','MISS req.','Duration','Rate','HIT rate','MISS rate','First','Last','Largest');
push @full_heads,'Denied' if $p{view} eq 'series';
push @heads,'Denied' if $p{view} eq 'series';
my @align=$p{view} eq 'denied' ? ('text','number','text','text','text','text') : ('text',('number') x 10,'text','text','text');
push @align,'number' if $p{view} eq 'series';
print '<div class="scroll"><table><thead><tr>'.join('',map {'<th scope="col" class="'.$align[$_].'" title="'.h($full_heads[$_]).'">'.$heads[$_].'</th>'} 0..$#heads).'</tr></thead><tbody>';
my $start=($p{page}-1)*100; my $end=$start+99; $end=$#keys if $end>$#keys;
for my $i ($start..$end) {
    my $key=$keys[$i]; my $r=$rows{$key};
    my $label=h($key);
    if ($p{view} eq 'networks' && $p{network} eq '') { $label='<a href="'.link_to(network=>$key,page=>1).'">'.$label.'</a>'; }
    elsif ($p{view} eq 'domains') { $label='<a href="'.link_to(view=>'sites',domain=>$key,page=>1).'">'.$label.'</a>'; }
    elsif ($p{view} eq 'sites' && $p{site} eq '') { $label='<a href="'.link_to(site=>$key,page=>1).'">'.$label.'</a>'; }
    elsif ($p{view} eq 'sites') { $label='<a href="'.link_to(user=>$key,site=>'',page=>1).'">'.$label.'</a>'; }
    my @cells;
    if ($p{view} eq 'denied') {
        @cells=($r->{requests},join('<br>',map {h($_)} sort keys %{$denied_users{$key}}),join('<br>',map {h($_.'='.$r->{codes}{$_})} sort keys %{$r->{codes}}),h(stamp($r->{first})),h(stamp($r->{last})));
    } else {
        @cells=($r->{requests}//0,fmtbytes($r->{bytes}//0),fmtbytes($r->{hit}//0),fmtbytes($r->{miss}//0),$r->{hit_requests}//0,$r->{miss_requests}//0,duration($r->{ms}),fmtrate($r,'bytes','ms'),fmtrate($r,'hit','hit_ms'),fmtrate($r,'miss','miss_ms'),h(stamp($r->{first})),h(stamp($r->{last})),defined($r->{max}) ? '<strong>Size:</strong> <span class="object-size">'.fmtbytes($r->{max}).'</span><br><strong>URL:</strong> '.h($r->{url}) : '—');
        push @cells,$r->{denied}//0 if $p{view} eq 'series';
    }
    print '<tr><th scope="row" class="text">'.$label.'</th>'.join('',map {'<td class="'.$align[$_+1].'">'.$cells[$_].'</td>'} 0..$#cells).'</tr>';
}
print '</tbody></table></div><nav aria-label="Pages">';
print '<a href="'.link_to(page=>$p{page}-1).'">Previous</a>' if $p{page}>1;
print '<span>Page '.$p{page}.' · '.scalar(@keys).' rows</span>';
print '<a href="'.link_to(page=>$p{page}+1).'">Next</a>' if $end<$#keys;
print '</nav><section class="report-guide" aria-labelledby="report-guide-title"><h2 id="report-guide-title">Report guide</h2>';
print '<p>Duration sums request durations. Throughput is bytes divided by accumulated request duration; it is not link capacity. Zero-duration rates are unavailable.</p>' unless $p{view} eq 'denied';
print '<p>Recorded intervals only; absent intervals are not filled with zero.</p>' if $p{view} eq 'series';
print '<p>Charts are generated for this request. No chart files or HTML reports are saved.</p></section></main>';

print <<'SCROLL_SCRIPT';
<script>
document.querySelectorAll('.scroll').forEach((tableScroll) => {
    const table = tableScroll.querySelector('table');
    if (!table) return;
    const topScroll = document.createElement('input');
    topScroll.type = 'range';
    topScroll.className = 'table-scroll-top';
    topScroll.min = '0';
    topScroll.step = '1';
    topScroll.value = '0';
    topScroll.hidden = true;
    topScroll.setAttribute('aria-label', 'Table horizontal scroll');
    tableScroll.before(topScroll);
    topScroll.addEventListener('input', () => {
        tableScroll.scrollLeft = Number(topScroll.value);
    });
    tableScroll.addEventListener('scroll', () => {
        topScroll.value = String(tableScroll.scrollLeft);
    });
    const update = () => {
        const maximum = Math.max(0, tableScroll.scrollWidth - tableScroll.clientWidth);
        topScroll.max = String(maximum);
        topScroll.hidden = maximum === 0;
        topScroll.value = String(tableScroll.scrollLeft);
    };
    const observer = new ResizeObserver(update);
    observer.observe(tableScroll);
    observer.observe(table);
    update();
});
</script></body></html>
SCROLL_SCRIPT
