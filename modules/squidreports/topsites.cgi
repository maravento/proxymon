#!/usr/bin/perl
# Squidreports - topsites
# FILE: squidreports/topsites.cgi
# topsites.cgi
#
# Squidreports is a reimplementation of LightSquid, modified by maravento in 2026.
# Original work: LightSquid Project (c) 2004-2005 Sergey Erokhin aka ESL
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# See the GNU General Public License for more details.

print "Content-Type: text/html\n\n";

use File::Basename;
push (@INC,(fileparse($0))[1]);

use CGI;
require "squidreports.cfg";
require "paths.pl";
require "common.pl";
require "WeeklyReport.pm";


$co=new CGI;

$year       =$co->param('year');
$month      =$co->param('month');
$day        =$co->param('day');
$sortorder  =$co->param('order');
$sortorder ||='size';

# Validate: year=4 digits, month/day=2 digits (empty allowed, matches prior behavior)
MyDie("invalid year/month/day\n") if ($year ne "" && $year !~ /^\d{4}$/);
MyDie("invalid year/month/day\n") if ($month ne "" && $month !~ /^\d{2}$/ && !(($co->param('mode') // '') =~ /^(week|year)$/ && $month eq "all"));
MyDie("invalid year/month/day\n") if ($day ne "" && $day !~ /^\d{2}$/);

InitTPL("topsites", scalar $co->param('tpl'));

ReplaceTPL(WEEK_CONTROLS, "");
my $weekly;
if (($co->param('mode') // '') eq 'week') {
  $weekly = eval { WeeklyReport::metro_context($co, $reportpath) };
  MyDie("invalid weekly period") unless $weekly;
  ReplaceTPL(WEEK_CONTROLS, $weekly->{controls});
}



$mode =$co->param('mode');

if ($weekly) {
  $mode="week";
  $workperiod=$weekly->{title};
} elsif ($mode eq "month") {
  $workperiod="##MSG_WHOLE## ##MSG_MONTH## - $year $MonthName[$month]";
  $mask = "$year$month*";
} elsif ($mode eq "year") {
  $workperiod="##MSG_WHOLE## ##MSG_YEAR## - $year";
  $mask = "$year*";
} else {
  $mode="day";
  $workperiod="$day $MonthName[$month] $year";
  $mask = "$year$month$day";
}

$n=1;
$printdotflag=0;

#$workperiod="$day $MonthName[$month] $year";

$sorturl  ="topsites.cgi?year=$year&month=$month&day=$day";
$sorturl .="&mode=$mode" if ($mode ne "day");
$sorturl .= $weekly->{query} if $weekly;
$sorturl .="&order";

$sortconnecturl_L = "$sorturl=hits";
$sortconnecturl_B = "##MSG_CONNECT##";
$sortbytesurl_L   = "$sorturl=size";
$sortbytesurl_B   = "##MSG_BYTES##";

$sortconnectattr = ($sortorder eq "hits")?"$hTPLVARIABLE{selectedattr}":"";
$sortbytesattr   = ($sortorder eq "size")?"$hTPLVARIABLE{selectedattr}":"";

@days=$weekly ? sort(map { glob("$_/*") } @{$weekly->{dirs}}) : sort glob("$reportpath/$mask/*");
@days=reverse @days;

foreach $userpath (@days) {
   next if ($userpath =~ m/^\./);

   $userpath =~ m/\d\/(.*)$/;
   $user=$1;

   open FF,"<$userpath";
    $totalsize=<FF>;chomp $totalsize;$totalsize=~s/total: //;
    $total+=$totalsize;
    while (<FF>) {
      ($site,$size,$hit)=split;
      $hash{hits}{$site}+=$hit;
      $hash{size}{$site}+=$size;
    }
   close FF;
}

$whourl = "whousesite.cgi?year=$year&month=$month&day=$day";
$whourl .="&mode=$mode" if ($mode ne "day");
$whourl .= $weekly->{query} if $weekly;
$whourl .="&usersite";

$N=0;
foreach $site (sort {$hash{$sortorder}{$b} <=> $hash{$sortorder}{$a}} keys  %{$hash{$sortorder}}) {

  # A period of zero byte requests is valid, and every share of zero is zero
  $percent  =($total > 0)?sprintf("%2.1f",int($hash{size}{$site}*1000/$total)/10):"0.0";
#  $percent  ="0.0";
  $printhit =FineDec($hash{hits}{$site});
  $printsize=FineDec($hash{size}{$site});
  
  $siteurlwho_L = "$whourl=" . escapeHtml($site);
  $siteurlwho_B = "##MSG_WHO##";
  $siteurl_L    = "http://" . escapeHtml($site);
  $siteurl_B    = escapeHtml($site);

  $N++;
  
  if ($N > $topsiteslimit) {
   unless ($printdotflag) {
     $printdotflag=1;

     $rowattr = ($N & 1)?$hTPLVARIABLE{oddattr}:$hTPLVARIABLE{evenattr};
     $dotN=$N; #for color flipper

     $tmp=$hTPL{site};
     $tmp=~s/##SITENUM##//;
     $tmp=~s/##SITEURLWHO_L##//;
     $tmp=~s/##SITEURLWHO_B##/\.\.\./;
     $tmp=~s/##SITEURL_L##//;
     $tmp=~s/##SITEURL_B##/\.\.\./;
     $tmp=~s/##SITECONNECT##/\.\.\./;
     $tmp=~s/##SITEBYTES##/\.\.\./;
     $tmp=~s/##SITEPERCENT##//;
     $tmp=~s/##ROWATTR##/$rowattr/;
     $tpl{site} .= $tmp;

   }
   next;
  }

  $rowattr = ($N & 1)?$hTPLVARIABLE{oddattr}:$hTPLVARIABLE{evenattr};
 
  $tmp=$hTPL{site};
  $tmp=~s/##SITENUM##/$N/;
  $tmp=~s/##SITEURLWHO_L##/$siteurlwho_L/;
  $tmp=~s/##SITEURLWHO_B##/$siteurlwho_B/;
  $tmp=~s/##SITEURL_L##/$siteurl_L/;
  $tmp=~s/##SITEURL_B##/$siteurl_B/;
  $tmp=~s/##SITECONNECT##/$printhit/;
  $tmp=~s/##SITEBYTES##/$printsize/;
  $tmp=~s/##SITEPERCENT##/$percent/;
  $tmp=~s/##ROWATTR##/$rowattr/;
  $tpl{site} .= $tmp;
}
close FF;

if ($printdotflag) {
  $rowattr = (($dotN+1) & 1)?$hTPLVARIABLE{oddattr}:$hTPLVARIABLE{evenattr};
  $tmp=$hTPL{site};
  $tmp=~s/##SITENUM##/$N/;
  $tmp=~s/##SITEURLWHO_L##/$siteurlwho_L/;
  $tmp=~s/##SITEURLWHO_B##/$siteurlwho_B/;
  $tmp=~s/##SITEURL_L##/$siteurl_L/;
  $tmp=~s/##SITEURL_B##/$siteurl_B/;
  $tmp=~s/##SITECONNECT##/$printhit/;
  $tmp=~s/##SITEBYTES##/$printsize/;
  $tmp=~s/##SITEPERCENT##/$percent/;
  $tmp=~s/##ROWATTR##/$rowattr/;
  $tpl{site} .= $tmp;
}

$totalprint=FineDec($total);

ReplaceTPL(TOTAL,$totalprint);
ReplaceTPL_URL(SORTCONNECTURL,$sortconnecturl_L,$sortconnecturl_B);
ReplaceTPL(SORTCONNECTATTR,$sortconnectattr);
ReplaceTPL_URL(SORTBYTESURL,$sortbytesurl_L,$sortbytesurl_B);
ReplaceTPL(SORTBYTESATTR,$sortbytesattr);
ReplaceTPL(DATE,$workperiod);

ApplyTPL();
PrintTPL();

