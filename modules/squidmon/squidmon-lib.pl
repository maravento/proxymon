# Squidmon - squidmon lib
# FILE: squidmon/squidmon-lib.pl
use File::Basename ();
#!/usr/bin/perl
# squidmon-lib.pl

do (File::Basename::dirname(__FILE__).'/squidmon-standalone.pl');
&init_config();

1;
