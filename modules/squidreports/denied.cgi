#!/usr/bin/perl
# denied.cgi
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

$year       =$co->param('year');
$month      =$co->param('month');
$day        =$co->param('day');
$filteruser =$co->param('user');

# Validate: year=4 digits, month/day=2 digits, user=safe charset with no '..'
MyDie("invalid year/month/day\n") unless ($year =~ /^\d{4}$/ && $month =~ /^\d{2}$/ && $day =~ /^\d{2}$/);
if ($filteruser ne "" && ($filteruser !~ /^[A-Za-z0-9._@-]+$/ || $filteruser =~ /\.\./)) {
    $filteruser = "";
}

InitTPL("denied", scalar $co->param('tpl'));

$workperiod=" $day $MonthName[$month] $year";

# .denied only exists on days that had denied requests, an empty table is
# the correct answer for a day where nothing was blocked
$N=0;

if (open FF,"<".StatisticsFile("$year$month$day", ".denied")) {
  while (<FF>) {
    chomp;
    ($user,$time,$code,$url)=split /\t/,$_,4;
    next if ($user eq "");

    if ($filteruser ne "") {
      next unless ($filteruser eq $user);
    }

    $N++;

    $rowattr = ($N & 1)?$hTPLVARIABLE{oddattr}:$hTPLVARIABLE{evenattr};

    $url_L=URLEncode("user_detail.cgi?year=$year&month=$month&day=$day&user=$user");
    $url_L =~ s/#/%23/;
    $url_B=escapeHtml($user);

    $tmp=$hTPL{denied};
    $tmp=~s/##DNNUM##/$N/;
    $tmp=~s/##DNTIME##/$time/;
    $tmp=~s/##DNUSER_L##/$url_L/;
    $tmp=~s/##DNUSER_B##/$url_B/;
    $tmp=~s/##DNCODE##/escapeHtml($code)/e;
    $tmp=~s/##DNURL##/escapeHtml($url)/e;
    $tmp=~s/##ROWATTR##/$rowattr/;
    $tpl{denied} .= $tmp;
  }
  close FF;
}

$tmp=$hTPL{denied};
$tmp=~s/##DNNUM##/ /;
$tmp=~s/##DNTIME##/ /;
$tmp=~s/##DNUSER_L##//;
$tmp=~s/##DNUSER_B##/##MSG_TOTAL##/;
$tmp=~s/##DNCODE##/ /;
$tmp=~s/##DNURL##/$N/;
$tmp=~s/##ROWATTR##/$hTPLVARIABLE{total}/;
$tpl{denied} .= $tmp;

ReplaceTPL(DATE,$workperiod);
ReplaceTPL(REPORTUSER,$filteruser);
ApplyTPL();
HideTPL("reportuser") if ($filteruser eq "");
PrintTPL();
