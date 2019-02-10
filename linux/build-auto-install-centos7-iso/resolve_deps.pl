#!/usr/bin/perl

my ($rpm_src_path, $rpm_dst_path, $arch) = @ARGV;

if (!-e $rpm_src_path)
{
    print_usage ("RPM source path '$rpm_src_path' does not exist");
}
if (!-e $rpm_dst_path)
{
    print_usage ("RPM destination path '$rpm_dst_path' does not exist");
}
if (!$arch)
{
    print_usage ("Architecture not specified");
}

print "Scanning all RPMs for capabilities provided...\n";
%providers = {};
open(my $fh_providers, '>/tmp/providers.txt');
foreach (<$rpm_src_path/*.rpm>)
{
    if (!m#(noarch|$arch)\.rpm$#)
    {
        next;
    }

    $rpm = $_;

    print ".";
    print $fh_providers "$rpm\n";

    $cmd = "rpm -q --provides -p $rpm 2>/dev/null";
    $output = `$cmd`;

    @lines = split ("\n", $output);

    foreach (@lines)
    {
        if (m#(.+)\s+=\s+\d#)
        {
            $capability = $1;
        }
        else
        {
            $capability = $_;
        }

        $rpm =~ m#([^/]+$)#;
        $rpm = $1;

        if ($providers{$capability} && ($providers{$capability} != $rpm))
        {
            print "WARNING: $capability is provided by " . $providers{$capability} . " and $rpm\n";
        }

        print $fh_providers "  $capability\n";
        $providers{$capability} = $rpm;
    }
}
close $fh_providers;

print "\n";

@queue = ();
%copied_packages = {};
foreach (<$rpm_dst_path/*rpm>)
{
    push (@queue, $_);
    my ($filename) = (m#/([^/]+)$#);
    my ($package_name) = ($filename =~ m#/(.+?)-\d#);
    $copied_packages{$package_name} = 1;
}

while (@queue)
{
    $rpm_name = pop (@queue);

    print "checking $rpm_name...\n";
    $cmd = "rpm -qRp $rpm_name 2>/dev/null | sort | uniq";
    #print "$cmd\n";
    @output = `$cmd`;

    foreach (@output)
    {
        s/^\s+//;
        s/\s+$//;
        s/\s+[<>=].+$//;  # strip off stuff like " >= 2003a"

        if ($providers{$_})
        {
            $new_path = "$rpm_dst_path/" . $providers{$_};

            if (-e $new_path)
            {
                #### already have this RPM in the directory...
                next;
            }
            print " requires $_ ==> " . $providers{$_} . "\n";

            push (@queue, $new_path);

            $newrpm = "$rpm_src_path/" . $providers{$_};
            $cmd = "cp $newrpm $rpm_dst_path";
            print "  $cmd\n";
            `$cmd 2>&1`;
        }
    }
}

sub print_usage
{
    my ($msg) = @_;

    ($msg) && print "$msg\n\n";

    print <<__TEXT__;
follow_deps.pl rpm_src_path rpm_dst_path arch

    rpm_src_path    the full path to the directory of all RPMs from the distro

    rpm_dst_path    the full path to the directory where you want to copy
                    the RPMs for your kickstart

    arch            the target system architecture (e.g. x86_64)


__TEXT__

    exit;
}
