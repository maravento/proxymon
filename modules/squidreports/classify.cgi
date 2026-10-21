#!/usr/bin/perl
# Squidreports - classify
# FILE: squidreports/classify.cgi
# classify.cgi
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
$type  =$co->param('type');

# Validate: year=4 digits, month/day=2 digits
MyDie("invalid year/month/day\n") unless ($year =~ /^\d{4}$/ && $month =~ /^\d{2}$/ && $day =~ /^\d{2}$/);

# The three aggregations share one layout, only the report file and the
# first column header change
%hClassify = (
  mime   => [".mime",  "##MSG_MIME_TYPE##"],
  ext    => [".ext",   "##MSG_EXTENSION##"],
  subnet => [".subnet","##MSG_SUBNET##"],
);

$type="mime" unless (defined $hClassify{$type});
($srcfile,$keylabel)=@{$hClassify{$type}};

InitTPL("classify", scalar $co->param('tpl'));

$workperiod=" $day $MonthName[$month] $year";

open FF,"<".StatisticsFile("$year$month$day", $srcfile) or MyDie("can't open $srcfile");

@rows=();
$total=0;
$totalhit=0;

while (<FF>) {
  chomp;
  ($key,$size,$hit)=split /\t/,$_,3;
  next if ($key eq "");
  push @rows,[$key,$size,$hit];
  $total    += $size;
  $totalhit += $hit;
}

close FF;

$N=0;

foreach $row (@rows) {
  ($key,$size,$hit)=@$row;
  $N++;

  $rowattr = ($N & 1)?$hTPLVARIABLE{oddattr}:$hTPLVARIABLE{evenattr};

  $tmp=$hTPL{classify};
  $tmp=~s/##CLNUM##/$N/;
  $tmp=~s/##CLKEY##/escapeHtml($key)/e;
  $tmp=~s/##CLSIZE##/FineDec($size)/e;
  $tmp=~s/##CLHIT##/FineDec($hit)/e;
  $tmp=~s/##CLPERCENT##/SharePercent($size,$total)/e;
  $tmp=~s/##ROWATTR##/$rowattr/;
  $tpl{classify} .= $tmp;
}

$tmp=$hTPL{classify};
$tmp=~s/##CLNUM##/ /;
$tmp=~s/##CLKEY##/##MSG_TOTAL##/;
$tmp=~s/##CLSIZE##/FineDec($total)/e;
$tmp=~s/##CLHIT##/FineDec($totalhit)/e;
$tmp=~s/##CLPERCENT##/100.00/;
$tmp=~s/##ROWATTR##/$hTPLVARIABLE{total}/;
$tpl{classify} .= $tmp;

ReplaceTPL(DATE,$workperiod);
ReplaceTPL(CLASSLABEL,$keylabel);
ApplyTPL();
PrintTPL();

# Share of the day traffic taken by one key
sub SharePercent($$) {
  my $size=shift;
  my $all=shift;
  return "0.00" if ($all == 0);
  return sprintf("%3.2f",($size*100)/$all);
}
