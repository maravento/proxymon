#!/usr/bin/perl
# userstat.cgi
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

$co=new CGI;

$year  =$co->param('year');
$month =$co->param('month');
$day   =$co->param('day');

# Validate: year=4 digits, month/day=2 digits
MyDie("invalid year/month/day\n") unless ($year =~ /^\d{4}$/ && $month =~ /^\d{2}$/ && $day =~ /^\d{2}$/);

InitTPL("userstat", scalar $co->param('tpl'));

$workperiod=" $day $MonthName[$month] $year";

open FF,"<".StatisticsFile("$year$month$day", ".userstat") || MyDie("can't open .userstat");

$N=0;
$allhit=0;
$allmiss=0;

while (<FF>) {
  chomp;
  ($user,$cachehit,$cachemiss,$elapsed,$maxsize,$maxurl)=split /\t/,$_,6;
  next if ($user eq "");

  $N++;
  $allhit  += $cachehit;
  $allmiss += $cachemiss;

  $rowattr = ($N & 1)?$hTPLVARIABLE{oddattr}:$hTPLVARIABLE{evenattr};

  $url_L=URLEncode("user_detail.cgi?year=$year&month=$month&day=$day&user=$user");
  $url_L =~ s/#/%23/;
  $url_B=escapeHtml($user);

  $tmp=$hTPL{userstat};
  $tmp=~s/##USNUM##/$N/;
  $tmp=~s/##USUSER_L##/$url_L/;
  $tmp=~s/##USUSER_B##/$url_B/;
  $tmp=~s/##USHITPERCENT##/HitPercent($cachehit,$cachemiss)/e;
  $tmp=~s/##USCACHEHIT##/FineDec($cachehit)/e;
  $tmp=~s/##USCACHEMISS##/FineDec($cachemiss)/e;
  $tmp=~s/##USDURATION##/FineTime($elapsed)/e;
  $tmp=~s/##USTHROUGHPUT##/FineRate($cachehit+$cachemiss,$elapsed)/e;
  $tmp=~s/##USLARGEST##/LargestCell($maxsize,$maxurl)/e;
  $tmp=~s/##ROWATTR##/$rowattr/;
  $tpl{userstat} .= $tmp;
}

close FF;

$tmp=$hTPL{userstat};
$tmp=~s/##USNUM##/ /;
$tmp=~s/##USUSER_L##//;
$tmp=~s/##USUSER_B##/##MSG_TOTAL##/;
$tmp=~s/##USHITPERCENT##/HitPercent($allhit,$allmiss)/e;
$tmp=~s/##USCACHEHIT##/FineDec($allhit)/e;
$tmp=~s/##USCACHEMISS##/FineDec($allmiss)/e;
$tmp=~s/##USDURATION##/ /;
$tmp=~s/##USTHROUGHPUT##/ /;
$tmp=~s/##USLARGEST##/ /;
$tmp=~s/##ROWATTR##/$hTPLVARIABLE{total}/;
$tpl{userstat} .= $tmp;

ReplaceTPL(DATE,$workperiod);
ApplyTPL();
PrintTPL();

# Share of the traffic that squid served from its own cache
sub HitPercent($$) {
  my $hit=shift;
  my $miss=shift;
  my $all=$hit+$miss;
  return "0.00" if ($all == 0);
  return sprintf("%3.2f",($hit*100)/$all);
}

# Squid reports the elapsed time of each request in milliseconds
sub FineTime($) {
  my $ms=shift;
  my $sec=int($ms/1000);
  return sprintf("%d:%02d:%02d",int($sec/3600),int(($sec%3600)/60),$sec%60);
}

# Average transfer rate, bytes moved over the time spent moving them
sub FineRate($$) {
  my $bytes=shift;
  my $ms=shift;
  return "-" if ($ms <= 0);
  return FineDec(int(($bytes*1000)/$ms))."/s";
}

# Largest object of the user, shown as "size url"
sub LargestCell($$) {
  my $size=shift;
  my $url=shift;
  return "-" if ($size <= 0);
  return FineDec($size)."&nbsp;&nbsp;".escapeHtml($url);
}
