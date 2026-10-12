#!/usr/bin/perl
# whousesite.cgi
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

$mode="day";

$year       =$co->param('year');
$month      =$co->param('month');
$day        =$co->param('day');
$usersite   =$co->param('usersite');
$mode       =$co->param('mode');

# Validate: year=4 digits, month/day=2 digits (falls back to "day" mode's
# own defaults below if missing); usersite must not carry HTML metachars.
MyDie("invalid year/month/day\n") if ($year ne "" && $year !~ /^\d{4}$/);
MyDie("invalid year/month/day\n") if ($month ne "" && $month !~ /^\d{2}$/);
MyDie("invalid year/month/day\n") if ($day ne "" && $day !~ /^\d{2}$/);
$usersite = "" if ($usersite =~ /[<>"'&]/);

InitTPL("whousesite", scalar $co->param('tpl'));

if      ($mode eq "month") {
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
	      


#@days=sort glob("$reportpath/$year$month$day/*");
@days=sort glob("$reportpath/$mask/*");
@days=reverse @days;

foreach $userpath (@days) {
   next if ($userpath =~ m/\^./);

   $userpath =~ m/\/(\d*)\/(.*)$/;
   $user=$2;
   $date=$1;

   GetRealName("$reportpath/$date/","?");

   open FF,"<$userpath";
    $totalsize=<FF>;chomp $totalsize;$totalsize=~s/total: //;
    while (<FF>) {
      ($site,$size,$hit)=split;
      next unless ($site eq $usersite);
      $hash{$user}+=$size;
      $hhit{$user}+=$hit;
      $hday{$user}{$date}=1;
      $total   +=$size;
      $hittotal+=$hit;
    }
   close FF;
}


$N=0;
foreach $user (sort {$hash{$b} <=> $hash{$a}} keys %hash) {
    $listid=0;
    $N++;
    $printsize   =FineDec($hash{$user});
    $printconnect=FineDec($hhit{$user});
  
    $usedaylist="";
#    if ($mode ne "day") {
	foreach $date (sort keys %{$hday{$user}} ) {
	    $date =~ m/(\d\d\d\d)(\d\d)(\d\d)/;
	    $daylist[$listid  ]{'L'}= URLEncode("user_detail.cgi?year=$1&month=$2&day=$3&user=$user");
	    $daylist[$listid++]{'B'}= GetTxtDate($date);
	}
#    }

    $rowattr = ($N & 1)?$hTPLVARIABLE{oddattr}:$hTPLVARIABLE{evenattr};
    
    $realname = GetRealName("?",$user);
 
    $tmp=$hTPL{who};
    $tmp=~s/##WHOUSER##/$user/;
    $tmp=~s/##REALNAME##/$realname/;	
    $tmp=~s/##WHOCONNECT##/$printconnect/;
    $tmp=~s/##WHOSIZE##/$printsize/;
    $tmp=~s/##USEDAYURL_L##/$daylist[0]{'L'}/;
    $tmp=~s/##USEDAYURL_B##/$daylist[0]{'B'}/;
    $tmp=~s/##ROWATTR##/$rowattr/;
    $tpl{who} .= $tmp;
  
    for ($i=1;$i<$listid;$i++) {
	$tmp=$hTPL{who};
	$tmp=~s/##WHOUSER##//;
	$tmp=~s/##REALNAME##//;	
	$tmp=~s/##WHOCONNECT##//;
	$tmp=~s/##WHOSIZE##//;
        $tmp=~s/##USEDAYURL_L##/$daylist[$i]{'L'}/;
	$tmp=~s/##USEDAYURL_B##/$daylist[$i]{'B'}/;
	$tmp=~s/##ROWATTR##/$rowattr/;
	$tpl{who} .= $tmp;
    }
}
close FF;

$totalprint=FineDec($total);
$totalhitprint=FineDec($hittotal);

ReplaceTPL(TOTAL,$totalprint);
ReplaceTPL(TOTALCONNECT,$totalhitprint);
ReplaceTPL(SITE,$usersite);
ReplaceTPL(DATE,$workperiod);

	      
ApplyTPL();
#HideTPL("daylist") if ($mode eq "day");
HideTPL("realname")   if ($userealname == 0);
PrintTPL();

