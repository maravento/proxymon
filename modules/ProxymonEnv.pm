package ProxymonEnv;
use strict;
use warnings;
sub read_env {
    my ($path)=@_;
    $path //= '/etc/proxymon/proxymon.env';
    open my $fh,'<',$path or die "Cannot read proxymon.env\n";
    my %env;
    while (<$fh>) {
        chomp;
        next if /^\s*(?:#|$)/;
        die "Invalid proxymon.env line\n" unless /^([A-Z][A-Z0-9_]*)=(.*)$/;
        my ($key,$value)=($1,$2);
        $value=$2 if $value =~ /^(['"])(.*)\1$/;
        $value =~ s{\$\{([A-Z][A-Z0-9_]*)\}|\$([A-Z][A-Z0-9_]*)}{my $ref=defined($1) ? $1 : $2; exists $env{$ref} ? $env{$ref} : die "Unknown environment reference\n"}ge;
        $env{$key}=$value;
    }
    close $fh or die "Cannot finish reading proxymon.env\n";
    return \%env;
}
sub required {
    my ($env,$key)=@_;
    die "$key missing or empty in proxymon.env\n" unless defined($env->{$key}) && length($env->{$key});
    return $env->{$key};
}
1;
