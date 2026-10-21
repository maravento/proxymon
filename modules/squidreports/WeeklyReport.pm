# Squidreports - WeeklyReport
# FILE: squidreports/WeeklyReport.pm
package WeeklyReport;
use strict;
use warnings;
use POSIX qw(strftime);
use Time::Local qw(timelocal);
use File::Basename qw(basename);
use CGI qw(escapeHTML);

sub default_week {
    my ($root,$year,$month)=@_;
    opendir my $dh,$root or return strftime('%G-%V',localtime);
    my @dates=sort grep { /^\d{8}$/ && -f "$root/$_/.total" && substr($_,0,4) eq $year && ($month eq 'all' || $month eq '' || substr($_,4,2) eq $month) } readdir $dh;
    closedir $dh;
    return strftime('%G-%V',localtime) unless @dates;
    my ($y,$m,$d)=$dates[-1]=~/^(\d{4})(\d{2})(\d{2})$/;
    return strftime('%G-%V',localtime(timelocal(0,0,12,$d,$m-1,$y)));
}
sub dates {
    my ($year,$week,$scope)=@_;
    die "Invalid ISO week\n" unless $year =~ /^\d{4}$/ && $year>=1970 && $year<=9998 && $week =~ /^(0[1-9]|[1-4]\d|5[0-3])$/;
    die "Invalid week scope\n" unless $scope eq 'full' || $scope eq 'bandata';
    my $max=strftime('%V',localtime(timelocal(0,0,12,28,11,$year)));
    die "Invalid ISO week\n" if $week>$max;
    my $jan4=timelocal(0,0,12,4,0,$year);
    my $offset=strftime('%u',localtime($jan4))-1;
    my $monday=$jan4-$offset*86400+($week-1)*7*86400;
    return map { strftime('%Y%m%d',localtime($monday+$_*86400)) } 0..($scope eq 'bandata'?4:6);
}
sub form {
    my ($year,$week,$scope,$view,$user)=@_;
    my $out='<form method="get"><label>Year <input type="number" name="year" min="1970" max="9998" value="'.$year.'" required></label> <label>ISO week <input type="number" name="week" min="1" max="53" value="'.int($week).'" required></label> <label>Period <select name="scope">';
    $out.='<option value="full"'.($scope eq 'full'?' selected':'').'>Full week (Mon–Sun)</option><option value="bandata"'.($scope eq 'bandata'?' selected':'').'>Bandata (Mon–Fri)</option></select></label>';
    $out.='<input type="hidden" name="view" value="'.escapeHTML($view).'">';
    $out.='<input type="hidden" name="user" value="'.escapeHTML($user).'">' if defined($user) && length($user);
    return $out.' <button type="submit">Apply</button></form>';
}
sub metro_context {
    my ($q,$root)=@_;
    my $year=$q->param('year') // '';
    my $week=$q->param('week') // '';
    $week=sprintf('%02d',$week) if $week =~ /^\d{1,2}$/;
    my $scope=$q->param('scope') // 'full';
    my @expected=dates($year,$week,$scope);
    my @dirs=map {"$root/$_"} grep {-f "$root/$_/.total"} @expected;
    my @missing=grep {!-f "$root/$_/.total"} @expected;
    my $controls=form($year,$week,$scope,'',scalar $q->param('user'));
    $controls =~ s/<form method="get">/<form method="get" class="form-inline"><input type="hidden" name="mode" value="week"><input type="hidden" name="month" value="all">/;
    $controls =~ s/<button type="submit">/<button type="submit" class="btn btn-default">/;
    if (defined $q->param('usersite')) {
        $controls =~ s{</form>}{'<input type="hidden" name="usersite" value="'.escapeHTML(scalar $q->param('usersite')).'"></form>'}e;
    }
    $controls.='<details class="alert alert-warning"><summary>Incomplete reports: '.scalar(@missing).' '.(@missing==1?'day':'days').' missing.</summary><p>Unavailable dates: '.escapeHTML(join(', ',@missing)).'. Totals cover available reports only.</p></details>' if @missing;
    return {dirs=>\@dirs,title=>escapeHTML("$year-W$week · $expected[0]–$expected[-1]"),controls=>$controls,query=>'&week='.$week.'&scope='.$scope};
}

sub daily_totals {
    my ($root,$dates,$user)=@_;
    my $out='<h2>Daily breakdown</h2><div class="scroll"><table><thead><tr><th>Date</th><th>Requests</th><th>Bytes</th></tr></thead><tbody>';
    for my $date (@$dates) {
        my ($bytes,$hits)=(0,0);
        if (open my $fh,'<',"$root/$date/.total") {
            <$fh>; <$fh>;
            while (<$fh>) { my ($who,$size,$requests)=split; next unless defined $requests; next if defined($user) && length($user) && $who ne $user; $bytes+=$size; $hits+=$requests; }
            close $fh;
            $out.='<tr><td>'.escapeHTML($date).'</td><td>'.$hits.'</td><td>'.$bytes.' B</td></tr>';
        } else { $out.='<tr><td>'.escapeHTML($date).'</td><td colspan="2">Report unavailable</td></tr>'; }
    }
    return $out.'</tbody></table></div>';
}
1;
