# Squidreports - fixreport
# FILE: squidreports/tools/fixreport.pl
#/bin/perl
$|=1;

require "../squidreports.cfg";
require "../paths.pl";

sub FixDay($) {
  my $path=shift;
  my @userlist=glob ("$path/*");
  my $userfile;
  my @report;
  my $site;
  my $size;
  my $rest;
  
  foreach $userfile (@userlist) {
     undef @report;

     unless (-f $userfile) {
        print "\nWarning !!!, subfolder '$userfile' found, VERY strange ...\n";
        next;
     }

     open F,"<","$userfile" or die "can't open file '$userfile' - $!\n";
     @report=<F>;
     close F;

#     print "\t$userfile\n";
     for ($i=0;$i<$#report+1;$i++) {
       my $str=$report[$i];
       next if ($str =~ m/: /);

       ($site,$size,$rest)=split /\s+/,$str,3;
#       print "\t\t$str ->>> $site->$size\n";
       if ($size < 0) {
         $newsize=2147483648+(2147483648+$size);

         print "\nBug Found : $path -> $userfile ($size -> $newsize)\n";
       }
     }
  }
}



#MAIN

@days=sort glob("$reportpath/*");

foreach $daypath (sort @days) {
  next unless ($daypath =~ m/\d\d\d\d\d\d\d\d/);
  print "$daypath\r";

  FixDay($daypath);
}

