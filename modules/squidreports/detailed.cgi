#!/usr/bin/perl
# Detailed traffic reports integrated in Squidreports.
# Distributed under the project's GPL license; no SARG runtime dependency.
use strict;
use warnings;
use File::Basename qw(dirname basename);
use lib dirname(__FILE__);
use CGI qw(escapeHTML escape);
our ($reportpath);
require 'squidreports.cfg';
require "paths.pl";
require 'ReportAnalytics.pm';

my $q = CGI->new;
my $year = $q->param('year') // '';
my $month = $q->param('month') // 'all';
my $day = $q->param('day') // '';
my $week = $q->param('week') // '';
my $user = $q->param('user') // '';
my $view = $q->param('view') // '';
print "Content-Type: text/html; charset=UTF-8\nCache-Control: no-store\n\n";
sub fail { print '<p>'.escapeHTML($_[0]).'</p>'; exit; }
fail('Invalid user') if $user ne '' && ($user !~ /^[A-Za-z0-9_\@][A-Za-z0-9._\@-]*$/ || $user =~ /\.\./);
my %dates;
my $valid=eval {
    for my $root ($reportpath, ReportAnalytics::statistics_root($reportpath)) {
        $dates{basename($_)}=1 for ReportAnalytics::select_days($root,$year,$month,$day,$week);
    }
    1;
};
fail('Invalid calendar date or ISO week') unless $valid;
my @days = map { "$reportpath/$_" } sort keys %dates;
my $period = $week ne '' ? "$year-W$week" : $year . ($month eq 'all' ? '' : "-$month") . ($day eq '' ? '' : "-$day");
sub report_link {
    my ($who, $which) = @_;
    return 'detailed.cgi?year='.$year.'&amp;month='.$month.($day ne '' ? '&amp;day='.$day : '')
        .($week ne '' ? '&amp;week='.$week : '')
        .($who ne '' ? '&amp;user='.escape($who) : '').($which ne '' ? '&amp;view='.$which : '');
}
sub number { return sprintf('%.2f', $_[0]); }
sub percent { return $_[1] > 0 ? number(100*$_[0]/$_[1]).'%' : '0.00%'; }
sub bytes {
    my $n = shift;
    for my $unit ('B','KiB','MiB','GiB','TiB') {
        return number($n).' '.$unit if $n < 1024 || $unit eq 'TiB';
        $n /= 1024;
    }
}
sub duration {
    my $s = int($_[0]/1000);
    return sprintf('%d:%02d:%02d.%03d',int($s/3600),int($s/60)%60,$s%60,int($_[0])%1000);
}
sub readrows {
    my ($file) = @_;
    open my $fh, '<', $file or fail('Cannot read report: '.basename($file));
    my @rows = <$fh>;
    close $fh or fail('Cannot finish reading report');
    return @rows;
}
print '<!doctype html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Detailed Report</title><style>';
print 'body{font:14px system-ui,sans-serif;background:#eef3f8;color:#263746;margin:0;padding:24px}main{max-width:1500px;margin:auto}h1{color:#3598dc;font-weight:400}nav{display:flex;gap:12px;flex-wrap:wrap;margin:16px 0}a{color:#2675b5}nav a,nav button{display:inline-block;box-sizing:border-box;padding:8px;border:1px solid #8f8f9d;border-radius:2px;background:#e9e9ed;color:#263746;font:inherit;line-height:normal;text-decoration:none;cursor:pointer}nav a:hover,nav button:hover{background:#dbe4ee}nav a[aria-current="page"],nav a[aria-current="page"]:hover{background:#2675b5;border-color:#2675b5;color:white}nav a:focus-visible,nav button:focus-visible{outline:2px solid #176298;outline-offset:2px}table{border-collapse:collapse;background:white;width:100%}th,td{padding:9px;border:1px solid #dbe4ee;text-align:right}th{background:#3598dc;color:white}td:first-child,th:first-child{text-align:left}tbody tr:nth-child(even){background:#f7faff}.metrics{font-size:13px}.metrics th,.metrics td{padding:6px 4px}.metrics th:nth-child(4),.metrics th:nth-child(7),.metrics th:nth-child(8),.metrics th:nth-child(11){white-space:nowrap}.metrics th:nth-child(n+2):nth-child(-n+12),.metrics td:nth-child(n+2):nth-child(-n+12){width:1%}.metrics td:nth-child(n+2):nth-child(-n+12){white-space:nowrap}.metrics td:first-child,.metrics td:nth-child(13){overflow-wrap:anywhere}.metrics.users th:first-child,.metrics.users td:first-child{width:1%;white-space:nowrap;overflow-wrap:normal}.metrics td:nth-child(13){text-align:left}.object-size{white-space:nowrap}.scroll{overflow:auto}.notice{background:#fff3cd;padding:12px 0}.notice summary{cursor:pointer}.report-guide{margin-top:32px;border-top:1px solid #dbe4ee}button{padding:8px;cursor:pointer}@media print{nav,button{display:none}body{padding:0}}';
print '</style></head><body><main><h1>Detailed Report</h1><p>'.escapeHTML($period).($user ne '' ? ' · '.escapeHTML($user) : '').'</p><nav><a href="index.cgi?year='.$year.'&amp;month='.$month.'">Back to Reports</a><a'.($view ne 'denied'?' aria-current="page"':'').' href="'.report_link('','').'">Users</a><a'.($view eq 'denied'?' aria-current="page"':'').' href="'.report_link($user,'denied').'">Denied Accesses</a><a href="analytics.cgi?year='.$year.'&amp;month='.$month.($day ne ''?'&amp;day='.$day:'').($week ne ''?'&amp;week='.$week:'').'">Analyze</a><button onclick="window.print()">Print</button></nav>';
if ($view eq 'denied') {
    print '<div class="scroll"><table><thead><tr><th>Date</th><th>User</th><th>Time</th><th>Code</th><th>URL</th></tr></thead><tbody>';
    my $count = 0;
    for my $dir (@days) {
        my $deniedfile=ReportAnalytics::statistics_file($reportpath,basename($dir),".denied");
        next unless -f $deniedfile;
        for (readrows($deniedfile)) {
            chomp;
            my ($who,$time,$code,$url) = split /\t/, $_, 4;
            next if $user ne '' && $who ne $user;
            print '<tr>'.join('',map {'<td>'.escapeHTML($_ // '').'</td>'} (basename($dir),$who,$time,$code,$url)).'</tr>';
            $count++;
        }
    }
    print '</tbody></table></div><p>Requests: '.$count.'</p></main></body></html>';
    exit;
}
my %rows;
for my $dir (@days) {
    my %stats;
    my $statfile = $user eq '' ? '.userstat' : '.sitestat';
    my $statpath=ReportAnalytics::statistics_file($reportpath,basename($dir),$statfile);
    if (-f $statpath) {
        for (readrows($statpath)) {
            chomp;
            my @v = split /\t/, $_, 6;
            if ($user eq '') { $stats{shift @v} = \@v; }
            elsif (shift(@v) eq $user) { $stats{shift @v} = \@v; }
        }
    }
    my @base;
    if ($user eq '') {
        next unless -f "$dir/.total";
        @base = readrows("$dir/.total");
        splice @base,0,2;
    } else {
        next unless -f "$dir/$user";
        @base = readrows("$dir/$user");
        shift @base;
    }
    for (@base) {
        my ($key,$size,$hits) = split;
        next unless defined $hits;
        my $r = $rows{$key} //= {bytes=>0,hits=>0,hit=>0,miss=>0,ms=>0,complete=>1,max=>0,url=>''};
        $r->{bytes} += $size;
        $r->{hits} += $hits;
        if (exists $stats{$key}) {
            my ($hit,$miss,$ms,$max,$url) = @{$stats{$key}};
            $r->{hit} += $hit; $r->{miss} += $miss; $r->{ms} += $ms;
            if (defined $max && $max > $r->{max}) { $r->{max}=$max; $r->{url}=$url // ''; }
        } else { $r->{complete}=0; }
    }
}
my ($allbytes,$allhits,$allms,$allhit,$allmiss) = (0,0,0,0,0);
my $complete = 1;
for my $r (values %rows) {
    $allbytes += $r->{bytes}; $allhits += $r->{hits}; $allms += $r->{ms};
    $allhit += $r->{hit}; $allmiss += $r->{miss}; $complete &&= $r->{complete};
}
print '<details class="notice"><summary>Incomplete statistics</summary><p>Some dates lack detailed metrics. Unavailable values are shown as —. Regenerate those dates from available Squid logs to recover them.</p></details>' unless $complete;
my @heads = ($user eq '' ? 'User' : 'Site','Requests','Bytes','Bytes %','HIT','MISS','HIT %','MISS %','Duration','Avg. ms','Time %','Throughput');
push @heads,'Largest object' if $user eq '';
print '<div class="scroll"><table class="metrics'.($user eq ''?' users':' sites').'"><thead><tr>'.join('',map {'<th>'.$_.'</th>'} @heads).'</tr></thead><tbody>';
for my $key (sort {$rows{$b}{bytes}<=>$rows{$a}{bytes} || $a cmp $b} keys %rows) {
    my $r=$rows{$key};
    my @cells = ($user eq '' ? '<a href="'.report_link($key,'').'">'.escapeHTML($key).'</a>' : escapeHTML($key),$r->{hits},bytes($r->{bytes}),percent($r->{bytes},$allbytes));
    push @cells, $r->{complete} ? (bytes($r->{hit}),bytes($r->{miss}),percent($r->{hit},$r->{hit}+$r->{miss}),percent($r->{miss},$r->{hit}+$r->{miss}),duration($r->{ms}),$r->{hits}>0 ? number($r->{ms}/$r->{hits}) : '0.00') : ('—') x 6;
    push @cells, $complete ? percent($r->{ms},$allms) : '—';
    push @cells, $r->{complete} && $r->{ms}>0 ? bytes($r->{bytes}*1000/$r->{ms}).'/s' : '—';
    push @cells, $r->{complete} && $r->{max}>0 ? '<strong>Size:</strong> <span class="object-size">'.bytes($r->{max}).'</span><br><strong>URL:</strong> '.escapeHTML($r->{url}) : '—' if $user eq '';
    print '<tr>'.join('',map {'<td>'.$_.'</td>'} @cells).'</tr>';
}
print '</tbody><tfoot><tr><td>Total</td><td>'.$allhits.'</td><td>'.bytes($allbytes).'</td><td>'.percent($allbytes,$allbytes).'</td>';
my @totals = $complete ? (bytes($allhit),bytes($allmiss),percent($allhit,$allhit+$allmiss),percent($allmiss,$allhit+$allmiss),duration($allms),$allhits>0 ? number($allms/$allhits) : '0.00',percent($allms,$allms),$allms>0 ? bytes($allbytes*1000/$allms).'/s' : '—') : ('—') x 8;
print join('',map {'<td>'.$_.'</td>'} @totals);
print '<td>—</td>' if $user eq '';
print '</tr></tfoot></table></div><p>Users/sites: '.scalar(keys %rows).'</p><section class="report-guide" aria-labelledby="report-guide-title"><h2 id="report-guide-title">Report guide</h2><p>Duration is the sum of request durations. Average request duration is in milliseconds; throughput is bytes divided by accumulated request duration.</p></section></main></body></html>';
