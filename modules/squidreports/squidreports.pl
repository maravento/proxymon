#!/usr/bin/perl
# squidreports.pl
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

#parse access.log
# make per user report in 'report' direcotry

#usage: lightparse.pl {param}
#if param omit				 - parse full access.log file
#	today					 - only current day
#	yesterday				 - yesterday
#	data in format YYYYMMDD	 - parse day
#	access.log.{\d}.{gz|bz2} - parse file (for process archived)
#	--wait-lock				 - wait for another generator instead of exiting

# function prototypes
sub MakeReport();
sub InitSkipUser();
sub getLPS($$);
sub LockLSQ();
sub UnLockLSQ();
sub LOCKREMOVER();

use File::Basename;
use Time::Local;

push (@INC,(fileparse($0))[1]);

require "squidreports.cfg";
require "paths.pl";
require "common.pl";
require "ReportAnalytics.pm";
use JSON::PP;
use File::Path qw(make_path);
use File::Copy ();
use File::Temp ();
use Fcntl qw(:flock);
my $analytics = {};
my $network_rules=ReportAnalytics::network_rules($main::proxymon_settings,$analytics_networks // []);

#include ip2name function
require "ip2name/ip2name.$ip2name";

$SIG{INT} = \&LOCKREMOVER;	# traps keyboard interrupt
my $lockfilepath	  ="$lockpath/lockfile";

my $waitlock = grep { $_ eq "--wait-lock" } @ARGV;

my $tempsource = "";
END {
  if ($tempsource ne "" && -f $tempsource) {
	unlink $tempsource;
  }
}

my $skipurlcntr		  = 0;
my $skip4xxcntr		  = 0;
my $skipfilterdatecntr= 0;

my $firstrun	= 1;
my %closedday	= ();
my $totallines	= 0;
my $parsedlines = 0;
my $daylines	= 0;

my $catname	  ="cat";
my $filename = File::Basename::basename(ProxymonEnv::required($proxymon_settings,'SQUID_LOG_FILE'));
$logpath = File::Basename::dirname($proxymon_settings->{SQUID_LOG_FILE});

undef $workday;

exit($waitlock ? 1 : 0) unless (LockLSQ()); #Lock LSQ (block multiple instance)

if ($skipurl eq "") {
   $skipurl = "skipurl MUST be defined!!!";
   print "WARNING !!! \$skipurl is empty\n";
}	

($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime;
$month=sprintf("%02d",$mon+1);;
	  
my $filterdatestart=0;
my $filterdatestop =timelocal(59,59,23,31,11,2100)+1000;

$fToday=1 if ($ARGV[0] eq "today");
$fToday=1 if ($ARGV[0] eq "yesterday");

if ($fToday) {
   ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime;

   $filterdate=sprintf("%04d%02d%02d",$year+1900,$mon+1,$mday);;
   $filterdatestart=timelocal( 0, 0, 0,$mday,$mon,$year);
   $filterdatestop =timelocal(59,59,23,$mday,$mon,$year);
   print ">>> filter today: $filterdate\n" if ($debug);
}

if ($ARGV[0] eq "yesterday") {
   ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($filterdatestart-1);
   $filterdatestart=timelocal( 0, 0, 0,$mday,$mon,$year);
   $filterdatestop =timelocal(59,59,23,$mday,$mon,$year);
   $filterdate=sprintf("%04d%02d%02d",$year+1900,$mon+1,$mday);;
   print ">>> filter yesterday: $filterdate\n" if ($debug);
}

if ($ARGV[0] =~ m/^(\d\d\d\d)(\d\d)(\d\d)$/) {
   if ($2 < 1 || $2 > 12 || $3 < 1 || $3 > 31) {
	  print STDERR "ERROR: '$ARGV[0]' is not a valid YYYYMMDD date\n";
	  exit 1;
   }
   $filterdate=$ARGV[0];
   $filterdatestart=timelocal( 0, 0, 0,$3,$2-1,$1);
   $filterdatestop =timelocal(59,59,23,$3,$2-1,$1);
   print ">>> filter date:	$filterdate\n" if ($debug);
}

if ($ARGV[0] =~ m/access\.log\.(\d)/) {
   $filename=$ARGV[0];
   $catname="zcat" if ($ARGV[0] =~ m/\.gz$/);
   $catname="bzcat" if ($ARGV[0] =~ m/\.bz2$/);
}

print ">>> use file :: $logpath/$filename\n" if ($debug);
# "open ... |" reports success as soon as the child is forked, so a missing
# or unreadable file would only show up on the child's stderr and the run
# would still end with status zero. The source is checked here, and the
# reader's own exit status is checked after the loop.
unless (-f "$logpath/$filename" && -r _) {
   print STDERR "ERROR: can't read log file '$logpath/$filename'\n";
   exit 1;
}
my $readsource = "$logpath/$filename";
my $readcat    = $catname;

# Without a date filter the source can hold several days, and MakeReport()
# publishes each one as soon as the next appears. A reader that failed after
# that point would leave an existing day already overwritten with a partial
# total. The source is decompressed to a temporary file first, so the parser
# only ever sees content that was read in full. 'today', 'yesterday' and an
# explicit YYYYMMDD set $filterdate, so the cron does not take this path.
unless ($filterdate) {
   my $temp_fh;
   ($temp_fh,$tempsource) = File::Temp::tempfile("squidreports-XXXXXX", TMPDIR => 1);
   unless (open SRC, "$catname $logpath/$filename|") {
	  print STDERR "ERROR: can't read log file '$logpath/$filename'\n";
	  exit 1;
   }
   while (<SRC>) {
	  unless (print $temp_fh $_) {
		 print STDERR "ERROR: can't write a temporary copy of '$logpath/$filename': $!\n";
		 exit 1;
	  }
   }
   unless (close SRC) {
	  print STDERR "ERROR: '$catname $logpath/$filename' failed, report not written\n";
	  exit 1;
   }
   unless (close $temp_fh) {
	  print STDERR "ERROR: can't write a temporary copy of '$logpath/$filename': $!\n";
	  exit 1;
   }
   $readsource = $tempsource;
   $readcat	= "cat";
}
open FF, "$readcat $readsource|" || die "can't access log file\n";

InitSkipUser();

StartIp2Name();

undef %bigfile; $bigfilecnt=0;
while (<FF>) {
	chomp;
	$totallines++;

	if (0 == $squidlogtype) {
	   #squid native log
	   #970313965.619 1249	  denis.local TCP_MISS/200 2598 GET	   http://www.emalecentral.com/tasha/thm_4374x013.jpg -		DIRECT/www.emalecentral.com image/jpeg
	   # timestamp	  elapsed host		  type		   size method url													user  hierarechy					type

	   #speed optimization for FILTERDATE mode
	   $Ltimestamp=substr $_,0,11;
	   if ($Ltimestamp<$filterdatestart or $Ltimestamp>$filterdatestop) {
		  print ">>>> skipDafteFilter URL $Lurl\n$_" if ($debug2 >= 2 );
		  $skipfilterdatecntr++;
		  next;
	   };

	   ($Ltimestamp,$Lelapsed,$Lhost,$Ltype,$Lsize,$Lmethod,$Lurl,$Luser,$Lhierarchy,$Lconttype,@Lrest)=split;
	   ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($Ltimestamp);
	   $mon++; #fix, month start from 0
	   $date  =sprintf("%04d%02d%02d",$year+1900,$mon,$mday);

	   #check row with invalid record
	   if ( ($#Lrest >= 0) && ($#Lrest < 4) ) { 
		  $str=$_;
		  #maybe two concatenated record (first - truncated)
	  if ($str =~ m/(\d+\.\d+\s+\d+\s+(\d{1,3}\.){3}\d{1,3}\s+\w+\/\d+\s+\d+\w+\s+\S+\s+\S+\s+\S+\s+\w+\/\S+\s(-|([a-zA-Z\-]+\/[a-zA-Z\-]+)))$/) {
			$newstr=$1;
			($Ltimestamp,$Lelapsed,$Lhost,$Ltype,$Lsize,$Lmethod,$Lurl,$Luser,$Lhierarchy,$Lconttype)=split /\s+/,$newstr;
		  } else {
			# maybe source url contain SPACES, try concatenate ...
			while ($#Lrest != -1) {
			   $Lurl.="_$Luser";$Luser=$Lhierarchy;$Lhierarchy=$Lconttype;$Lconttype=shift @Lrest;
			}
			#do some sanity check
		unless (($Lhierarchy =~ m/\w+\/\S+/) and ($Lconttype =~ m/-|([a-zA-Z\-]+\/[a-zA-Z\-]+)/)) {
			   $notrecoveredlines++;
		   next;
			}
		  }
		  $recoveredlines++;
	   }
	} else {
	   #emulated httpd log
	   #192.168.3.40 - - [15/Apr/2005:11:46:35 +0300] "GET http://mail.yandex.ru/mboxjscript? HTTP/1.0" 200 2262 TCP_MISS :DIRECT
	   #192.168.3.40 - - [15/Apr/2005:11:46:35 +0300] "GET http://css.yandex.ru/css/mail/search.js HTTP/1.0" 200 4199 TCP_HIT:NONE
	   #192.168.3.12 -		 -		 [15/Apr/2005:11:46:35 +0300] "CONNECT aero.lufthansa.com:443 HTTP/1.0" 200 35992 TCP_MISS:DIRE
	   # ($Lhost,	  $Luser,$Luser2,$Ldate,			   $u2,	  $Lmethod,$Lurl,				  $u3,	   $Ltype,$Lsize,$u4)=split
 
	   ($Lhost,$Luser,$Luser2,$Ldate,$u2,$Lmethod,$Lurl,$u3,$Ltype,$Lsize,$u4)=split;
	   
	   $Ldate =~ m#^\[(\d\d)/(...)/(\d\d\d\d):(\d\d):(\d\d):(\d\d)#;
	   $mday=$1;$mon=$month2dec{$2};$year=$3-1900;
	   $hour=$4;$min=$5;$sec=$6;

	   $date  =sprintf("%04d%02d%02d",$year+1900,$mon,$mday);
	   if ($filterdate) {
		  if ($date ne $filterdate) {
			 print ">>>> skipDafteFilter URL $Lurl\n$_" if ($debug2 >= 2 );
			 $skipfilterdatecntr++;
			 next;
		  };
	   }
	   
	   if (($Luser eq "-") && ($Luser2 ne "-")) {
		 $Luser = $Luser2;
	   }
	   
	   $u4 =~ m/(.*?)\s?:(.*)/;
	   $Ltype = "$1/$Ltype";
	}  #if ($squidlogtype)
	
	if ($year < 2000-1900) { ; #invalid record
	   print ">>>> skipn Bad Year  $Lurl\n$_" if ($debug2 >= 1 );
	   $skipbadyear++;
	   next;
	}

	#skip intranet
	if ($Lurl =~ m/$skipurl/o) {
	  print ">>>> skipURL $Lurl\n$_" if ($debug2 >= 2 );
	  $skipurlcntr++;
	  next;
	};

	# Access denied records are reported apart, they never reach the totals.
	# They are stored per date because the day rollover below is driven by
	# the lines that do reach the totals, and these never do.
	if ($Ltype =~ m#DENIED#io) {
	  $skipDenied++;
	  print ">>>> skipDenied $Ltype\n$_" if ($debug2 >= 2);
	  $duser=lc $Luser;
	  $duser=$Lhost if (($duser eq "-") or ($duser eq ""));
	  $duser=SafeUserName($duser);
	  unless (defined $hSkipUser{$duser}) {
		push @{$denied{$date}},join("\t",
			$duser,
			sprintf("%02d:%02d:%02d",$hour,$min,$sec),
			$Ltype,
			$Lurl);
	  }
	  next;
	};
	
	$parsedlines++;
	
	if ($date ne $workday) { # close prev day, prepare for new
	  # A date already closed in this run must not be published again:
	  # MakeReport replaces the day, it does not add to it. Reaching here
	  # means the source interleaves dates, so the run stops before that
	  # day is overwritten with a partial total.
	  if (defined $closedday{$date}) {
		 print STDERR "ERROR: date '$date' reappears after being closed; source '$filename' is out of order\n";
		 exit 1;
	  }
	  if ($firstrun) {
		undef $firstrun;
		$workday=$date;
	  } else {
		MakeReport();
		$closedday{$workday}=1;
		$analytics = {};
		undef %totalsize; undef %sitesize; undef %sitehit;undef %totalhit;undef %totalputpost;
	undef %hashhost;undef %hashname;
		undef %bigfile; $bigfilecnt=0;
	undef %sitetime;undef %sitetimesize;
	undef %usercachehit;undef %usercachemiss;undef %userelapsed;
	undef %sitecachehit;undef %sitecachemiss;undef %siteelapsed;
	undef %userbigsize;undef %userbigurl;
	undef %mimesize;undef %mimehit;undef %extsize;undef %exthit;
	undef %subnetsize;undef %subnethit;
		$daylines=0;
		$workday=$date;
	$sqlreq=0;
	$CacheHIT=0;$CacheMISS=0;
	  }
	}
	$daylines++;

	$user=lc $Luser;
 
	$user = Ip2Name($Lhost,$user,$Ltimestamp);
	$user = SafeUserName($user);

	next if (defined $hSkipUser{$user});

	#simplified some common banner system & counters
	$url=$Lurl;
	$url =~ s/([a-z]+:\/\/)??.*\.(spylog\.com)/$1www.$2/o;
	$url =~ s/([a-z]+:\/\/)??.*\.(yimg\.com)/$1www.$2/o;
	$url =~ s/([a-z]+:\/\/)??.*\.(adriver\.ru)/$1www.$2/o;
	$url =~ s/([a-z]+:\/\/)??.*\.(bannerbank\.ru)/$1www.$2/o;
	$url =~ s/([a-z]+:\/\/)??.*\.(mail\.ru)/$1www.$2/o;
	$url =~ s/([a-z]+:\/\/)??.*\.(adnet\.ru)/$1www.$2/o;
	$url =~ s/([a-z]+:\/\/)??.*\.(rapidshare\.de)/$1www.$2/o;
	$url =~ s/([a-z]+:\/\/)??.*\.(rapidshare\.com)/$1www.$2/o;

	$url =~ s/([a-z]+:\/\/)??.*\.(vkontakte\.ru)/$1www.$2/o;
	$url =~ s/([a-z]+:\/\/)??.*\.(odnoklasniki\.ru)/$1www.$2/o;


	#extract site name
	if ($url =~ m/([a-z]+:\/\/)??([a-z0-9\-]+\.){1}(([a-z0-9\-]+\.){0,})([a-z0-9\-]+){1}(:[0-9]+)?\/(.*)/o) {
	   $site=$2.$3.$5;
	} else {
	   $site=$Lurl;
	}

	
	$site=$Lurl if ($site eq "");

	$totalsize	  {$user}		+=$Lsize;
	$totalhit	  {$user}		++;
	$totalputpost {$user}		+=$Lsize if (($Lmethod eq "PUT") or ($Lmethod eq "POST"));
	$sitesize	  {$user}{$site}+=$Lsize;
	$sitehit	  {$user}{$site}++;
	
	$sitetime	  {$user}{$site}[$hour]+=$Lelapsed;
	$sitetimesize {$user}{$site}[$hour]+=$Lsize;

	#.userstat support: per user cache, duration and largest object
	# The day totals in .features are accumulated here too, so they cover the
	# same clients as .total: a user listed in skipuser.cfg never reaches this
	# point. The day rollover above has already run, so the first request of a
	# new day stays out of the day being closed.
	if ($Ltype =~ m/HIT/) {
		$usercachehit  {$user}+=$Lsize;
		$sitecachehit {$user}{$site}+=$Lsize;
		$CacheHIT+=$Lsize;
	} else {
		$usercachemiss {$user}+=$Lsize;
		$sitecachemiss {$user}{$site}+=$Lsize;
		$CacheMISS+=$Lsize;
	}
	$userelapsed {$user}+=$Lelapsed;
	$siteelapsed {$user}{$site}+=$Lelapsed;
	if ($Lsize > ($userbigsize{$user}||0)) {
		$userbigsize {$user}=$Lsize;
		$userbigurl  {$user}=$Lurl;
	}

	#.mime support: content type is absent in the emulated httpd log
	$mime=$Lconttype||"-";
	$mime="-" unless ($mime =~ m#^[a-zA-Z\-]+/[a-zA-Z0-9\-\+\.]+$#);
	$mimesize {$mime}+=$Lsize;
	$mimehit  {$mime}++;
	ReportAnalytics::accumulate($analytics,$user,$Lhost,$Lurl,$mime,
	    $Lsize,$Lelapsed,($Ltype =~ /HIT/ ? 1 : 0),$Ltimestamp,$hour);

	#.ext support: extension of the requested object, query string removed
	$ext=$Lurl;
	$ext =~ s/[?#].*$//;
	if ($ext =~ m#/[^/]*\.([a-zA-Z0-9]{1,8})$#) {
		$ext=lc $1;
	} else {
		$ext="-";
	}
	$extsize {$ext}+=$Lsize;
	$exthit  {$ext}++;

	$subnet=ReportAnalytics::network($Lhost,$network_rules);
	$subnetsize {$subnet}+=$Lsize;
	$subnethit  {$subnet}++;

	#.bigfile support
	if ($Lsize > $bigfilelimit) {
		$bigfile [$bigfilecnt]{date}=sprintf("%02d:%02d:%02d",$hour,$min,$sec);
		$bigfile [$bigfilecnt]{link}=$Lurl;
		$bigfile [$bigfilecnt]{size}=$Lsize;
		$bigfile [$bigfilecnt]{user}=$user;
		$bigfilecnt++;
	}
}

unless (close FF) {
   # A non zero status from cat, zcat or bzcat means the log was only read
   # in part. Publishing that as a complete day would hide the loss.
   print STDERR "ERROR: '$catname $logpath/$filename' failed, report not written\n";
   exit 1;
}

MakeReport();

# Any date left in %denied had denials but no allowed traffic, so it never
# reached MakeReport(). Its report is published here.
foreach my $pendingdate (sort keys %denied) {
  WriteDenied($pendingdate);
}

StopIp2Name();
UnLockLSQ();

if ($debug) {
	$worktime = ( time() - $^T );
	print "run TIME: $worktime sec\n";
	print "Squidreports parser statistic report\n\n";
	printf( "	   %10u lines processed (average %.2f lines per second)\n",
		$totallines, getLPS( $worktime, $totallines ) );
	printf( "	   %10u lines parsed\n",				  $parsedlines );
	printf( "	   %10u lines recovered\n",				  $recoveredlines );
	printf( "	   %10u lines notrecovered\n",			  $notrecoveredlines );
	printf( "	   %10u lines skiped by bad year\n",	  $skipbadyear );
	printf( "	   %10u lines skiped by date filter\n",	  $skipfilterdatecntr );
	printf( "	   %10u lines skiped by Denied filter\n", $skipDenied );
	printf( "	   %10u lines skiped by skipURL filter\n", $skipurlcntr );

	if ( $parsedlines == 0 ) {
		print "\nWARNING !!!!, parsed 0 lines from total : $totallines\n";
		print "please check confiuration !!!!\n";
		print "may be wrong log format selected ?\n";
	}

}



# The END ---------------------------------------------------------

##Subroutines
# return Line Per Second value (check 0 values and correct)
sub getLPS($$) {
  my $time=shift;
  my $lines=shift;
  $time||=1;
  $lines||=1;
  return ($lines/$time);
}

# The report of a user is a file named after the user, and the user name
# comes from the proxy credentials in the log. A name carrying a directory
# separator would place that file outside its day. Names already fit for a
# file name are kept verbatim, so normal reports read exactly as before.
# Anything else is replaced by a hex form, which is unique, reversible and
# visibly not a real name.
sub SafeUserName($) {
  my $name=shift;

  return "unknown" unless (defined $name && $name ne "");
  return $name if ($name =~ m/^[A-Za-z0-9_\@][A-Za-z0-9._\@-]*$/ && $name !~ m/\.\./ && $name !~ /^enc\./);

  return "enc.".unpack("H*",$name);
}

# Publish a report file atomically: the content is written to a temporary
# neighbour and renamed into place. A reader opening the final name sees
# either the previous complete file or the new one, never the empty window
# that a plain ">" leaves while the file is being rewritten.
sub OpenAtomic($) {
  my $file=shift;
  # The staging name is dot prefixed on purpose: topsites.cgi and
  # whousesite.cgi list a day with glob("dir/*"), which skips dot files.
  # A plain "$file.$$.tmp" was listed as one more user while publishing.
  my ($dir,$base)=($file =~ m#^(.*)/([^/]+)$#) ? ($1,$2) : (".",$file);
  my $tmp="$dir/.tmp.$$.$base";
  open(my $fh,'>',$tmp) or die "can't create file $tmp - $!";
  return ($fh,$tmp);
}

sub CloseAtomic($$$) {
  my ($fh,$tmp,$file)=@_;
  close $fh or die "can't write $tmp - $!";
  rename $tmp,$file or die "can't rename $tmp to $file - $!";
}

# write a "key <tab> bytes <tab> hits" report, sorted by bytes
sub WriteKeyReport($$$) {
  my $file=shift;
  my $size=shift;
  my $hit=shift;

  my ($fh,$tmp)=OpenAtomic($file);
  foreach my $key (sort {$$size{$b} <=> $$size{$a}} keys %$size) {
	print $fh join("\t",$key,$$size{$key}+0,$$hit{$key}+0)."\n";
  }
  CloseAtomic($fh,$tmp,$file);
}

# Denied accesses and authentication failures of one day.
# format: user <tab> time <tab> squid code <tab> url
# Called for the day being closed, and again at the end of the run for any
# date that produced denials but no allowed traffic: those days never reach
# MakeReport() because the day rollover is driven by the allowed lines.
sub WriteDenied($) {
  my $date=shift;
  my $path=ReportAnalytics::statistics_root($reportpath)."/$date";

  make_path($path, {mode=>0755}) unless -d $path;

  my ($fh,$tmp)=OpenAtomic("$path/.denied");
  print $fh "$_\n" foreach (@{$denied{$date} || []});
  CloseAtomic($fh,$tmp,"$path/.denied");

  delete $denied{$date};
}

sub MakeReport() {
	#generate report
	#use global var 

	return if ($daylines < 1);

	print ">>> Make Report $workday ($daylines - log line parsed)\n" if ($debug);

	$reppath="$reportpath/$workday";

	unless ( -d $reppath )
	{
	  mkdir $reppath, 0755 or die "Can't create dir '$reppath': $!";
	}

	my ($totalfh,$totaltmp)=OpenAtomic("$reppath/.total");

	$tmp="";$tmpsize=0;$tmpuser=0;$tmpoveruser=0;

	foreach $tuser (sort {$totalsize{$b} <=> $totalsize{$a}} keys %totalsize) {
	  $totalputpost{$tuser}+=0; #prevent empty value
	  $tmp.=sprintf("%-20s %15s %15s %15s\n",$tuser,$totalsize{$tuser},$totalhit{$tuser},$totalputpost{$tuser});
	  $tmpuser++;
	  $tmpsize+=$totalsize{$tuser};
	  $tmpoveruser++ if ($totalsize{$tuser} >= $perusertrafficlimit);

	  my ($repfh,$reptmp)=OpenAtomic("$reppath/$tuser");

	  print $repfh "total: $totalsize{$tuser}\n";

	  foreach $tsite (sort {$sitesize{$tuser}{$b} <=> $sitesize{$tuser}{$a}} keys %{$sitesize{$tuser}} ) {
		  printf $repfh ("%-29s %12s %10s\t",$tsite,$sitesize{$tuser}{$tsite},$sitehit{$tuser}{$tsite});
	  if ($timereport != 0) {
			for ($hour=0;$hour<24;$hour++) {
		printf $repfh ("%d-%s ",int($sitetime{$tuser}{$tsite}[$hour]/3600),$sitetimesize{$tuser}{$tsite}[$hour]+0);
		}
	  }
		  print $repfh "\n";
	  }
	  CloseAtomic($repfh,$reptmp,"$reppath/$tuser");
	}

	my $cacheall = $CacheHIT + $CacheMISS;

	print $totalfh "user: $tmpuser\n";
	print $totalfh "size: $tmpsize\n";
	print $totalfh "$tmp";
	CloseAtomic($totalfh,$totaltmp,"$reppath/.total");

	my ($sec_,$min_,$hour_,$mday_,$mon_,$year_,$wday_,$yday_,$isdst_) = localtime;$mon_++;$year_+=1900;
	my $moddate=sprintf("%02d:%02d",$hour_,$min_)." ::	$mday_ $MonthName[$mon_] $year_";

	my ($featfh,$feattmp)=OpenAtomic("$reppath/.features");
	print $featfh "overuser: $tmpoveruser\n";
	print $featfh "cachehit%: ".sprintf("%3.2f",$cacheall ? 100*$CacheHIT/$cacheall : 0)."\n";
	print $featfh "cachehit: $CacheHIT\n";
	print $featfh "cachemiss: $CacheMISS\n";
	print $featfh "cacheall: $cacheall\n";
	print $featfh "modification: $moddate\n";
	CloseAtomic($featfh,$feattmp,"$reppath/.features");

	my $statdir=ReportAnalytics::statistics_root($reportpath)."/$workday";
	make_path($statdir, {mode=>0755}) unless -d $statdir;

	#per user cache, duration and largest object
	#format: user <tab> cachehit <tab> cachemiss <tab> elapsed_ms <tab> maxsize <tab> maxurl
	my ($statfh,$stattmp)=OpenAtomic("$statdir/.userstat");
	foreach $tuser (sort {$totalsize{$b} <=> $totalsize{$a}} keys %totalsize) {
	  print $statfh join("\t",
		  $tuser,
		  $usercachehit  {$tuser}+0,
		  $usercachemiss {$tuser}+0,
		  $userelapsed   {$tuser}+0,
		  $userbigsize   {$tuser}+0,
		  $userbigurl    {$tuser}||"-")."\n";
	}
	CloseAtomic($statfh,$stattmp,"$statdir/.userstat");

	my ($sitefh,$sitetmp)=OpenAtomic("$statdir/.sitestat");
	foreach my $statuser (sort keys %totalsize) {
	  foreach my $statsite (sort keys %{$sitesize{$statuser}}) {
	    print $sitefh join("\t", $statuser, $statsite,
	      $sitecachehit{$statuser}{$statsite}+0,
	      $sitecachemiss{$statuser}{$statsite}+0,
	      $siteelapsed{$statuser}{$statsite}+0)."\n";
	  }
	}
	CloseAtomic($sitefh,$sitetmp,"$statdir/.sitestat");

	my ($analyticsfh,$analyticstmp)=OpenAtomic("$statdir/analyzer.json");
	print $analyticsfh JSON::PP->new->canonical->encode({version=>1,data=>$analytics});
	CloseAtomic($analyticsfh,$analyticstmp,"$statdir/analyzer.json");

	WriteDenied($workday);

	#aggregations by content type, extension and client subnet
	WriteKeyReport("$statdir/.mime",  \%mimesize,  \%mimehit);
	WriteKeyReport("$statdir/.ext",   \%extsize,   \%exthit);
	WriteKeyReport("$statdir/.subnet",\%subnetsize,\%subnethit);

	if ($bigfilecnt != 0) {
	  my ($bigfh,$bigtmp)=OpenAtomic("$reppath/.bigfiles");
	  for ($i=0;$i<$bigfilecnt;$i++) {
		print $bigfh "$bigfile[$i]{user}\t$bigfile[$i]{date}\t$bigfile[$i]{size}\t$bigfile[$i]{link}\n";
	  }
	  CloseAtomic($bigfh,$bigtmp,"$reppath/.bigfiles");
	} else {
	  unlink "$reppath/.bigfiles";
	}

	# A regeneration publishes the users it just parsed. A user that no
	# longer appears would otherwise keep its file from the previous run,
	# and the readers that list the day with glob() would still show it.
	# Only plain report files are considered: glob() skips the dot files,
	# and those are published by name above.
	foreach my $stale (glob("$reppath/*")) {
	  next unless (-f $stale);
	  my $staleuser=$stale;
	  $staleuser =~ s#^.*/##;
	  next if (defined $totalsize{$staleuser});
	  unlink $stale;
	}

	CreateGroupFile($reppath);
	File::Copy::copy(ProxymonEnv::required($main::proxymon_settings,'REALNAME_CFG'),"$reppath/.realname")
	  or die "Cannot copy configured realname file\n";
}

sub InitSkipUser() {
 open F,"<".ProxymonEnv::required($main::proxymon_settings,'SKIPUSERS_CFG');
 while (<F>) {
   chomp;
   next if (/^#/);
   next if (/^\s*$/);
   my ($ip) = split(/\s+/, $_);
   $hSkipUser{$ip}=1;
 }
 close F;
}
# Lock support
# The kernel holds the lock while this process lives, so a slow run keeps it
# and a killed run releases it at once. The file is never removed: unlinking it
# while another process holds the lock would let a third one create a new file
# and run as well.
sub LockLSQ() {
   open LOCK,">>",$lockfilepath
	  or die "ERROR: cannot open '$lockfilepath': $!\n";

   unless (flock LOCK, ($waitlock ? LOCK_EX : (LOCK_EX | LOCK_NB))) {
	  print STDERR "ERROR: cannot lock '$lockfilepath': $!\n";
	  close LOCK;
	  return 0;
   }
   return 1;
}

sub UnLockLSQ() {
  close LOCK;
}

sub LOCKREMOVER() {
   print "INT happents, exit\n";
   exit;
}

