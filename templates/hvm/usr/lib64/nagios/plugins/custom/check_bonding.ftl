#!/usr/bin/perl
#
# DESCRIPTION: Nagios plugin for checking the status of bonded network
#              interfaces (masters and slaves) on Linux servers.
#
# AUTHOR: Trond H. Amundsen <t.h.amundsen@usit.uio.no>
#
# $Id: check_linux_bonding 15317 2009-10-09 11:51:00Z trondham $
#
# Copyright (C) 2009 Trond H. Amundsen
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

use strict;
use warnings;
use POSIX qw(isatty);
use Getopt::Long qw(:config no_ignore_case);
use Pod::Usage;

#---------------------------------------------------------------------
# Initialization and global variables
#---------------------------------------------------------------------

# If we don't have a TTY, the plugin is probably run by Nagios. In
# that case, redirect all output to STDERR to STDOUT. Nagios ignores
# output to STDERR.
if (! isatty(*STDOUT)) {
    open STDERR, '>&', 'STDOUT'
      or do { print "ERROR: Couldn't redirect STDERR to STDOUT\n"; exit 2; }
}

# Version and similar info
my $NAME    = 'check_linux_bonding';
my $VERSION = '1.1.0';
my $AUTHOR  = 'Trond H. Amundsen';
my $CONTACT = 't.h.amundsen@usit.uio.no';

# Exit codes
my $E_OK       = 0;
my $E_WARNING  = 1;
my $E_CRITICAL = 2;
my $E_UNKNOWN  = 3;

# Nagios error levels reversed
my %reverse_exitcode
  = (
     0 => 'OK',
     1 => 'WARNING',
     2 => 'CRITICAL',
     3 => 'UNKNOWN',
    );

# Options with default values
my %opt
  = ( 'timeout'     => 5,  # default timeout is 5 seconds
      'help'        => 0,
      'man'         => 0,
      'version'     => 0,
      'blacklist'   => [],
      'no_bonding'  => 'ok',
      'state'       => 0,
      'short-state' => 0,
      'linebreak'   => undef,
      'verbose'     => 0,
    );

# Get options
GetOptions('t|timeout=i'    => \$opt{timeout},
	   'h|help'         => \$opt{help},
	   'man'            => \$opt{man},
	   'V|version'      => \$opt{version},
	   'b|blacklist=s'  => \@{ $opt{blacklist} },
	   'n|no-bonding=s' => \$opt{no_bonding},
	   's|state'        => \$opt{state},
	   'short-state'    => \$opt{shortstate},
	   'linebreak=s'    => \$opt{linebreak},
	   'v|verbose'      => \$opt{verbose},
	  ) or pod2usage(-exitstatus => $E_UNKNOWN, -verbose => 0);

# If user requested help
if ($opt{'help'}) {
    pod2usage(-exitstatus => $E_OK, -verbose => 1);
}

# If user requested man page
if ($opt{'man'}) {
    pod2usage(-exitstatus => $E_OK, -verbose => 2);
}

# If user requested version info
if ($opt{'version'}) {
    print <<"END_VERSION";
$NAME $VERSION
Copyright (C) 2009 $AUTHOR
License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.

Written by $AUTHOR <$CONTACT>
END_VERSION
    exit $E_OK;
}

# Reports (messages) are gathered in this array
my @reports = ();


# Setting timeout
$SIG{ALRM} = sub {
    print "PLUGIN TIMEOUT: $NAME timed out after $opt{timeout} seconds\n";
    exit $E_UNKNOWN;
};
alarm $opt{timeout};

# Default line break
my $linebreak = isatty(*STDOUT) ? "\n" : '<br/>';

# Line break from option
if (defined $opt{linebreak}) {
    if ($opt{linebreak} eq 'REG') {
	$linebreak = "\n";
    }
    elsif ($opt{linebreak} eq 'HTML') {
	$linebreak = '<br/>';
    }
    else {
	$linebreak = $opt{linebreak};
    }
}

# Blacklisted interfaces
my @blacklist = defined $opt{blacklist} ? @{ get_blacklist() } : ();

# Translate text exit codes to values
my %text2exit
  = ( 'ok'       => $E_OK,
      'warning'  => $E_WARNING,
      'critical' => $E_CRITICAL,
      'unknown'  => $E_UNKNOWN,
    );

# Check syntax of '--no-bonding' option
if (!exists $text2exit{$opt{no_bonding}}) {
    unknown_error("Wrong usage of '--no-bonding' option: '"
		  . $opt{no_bonding}
		  . "' is not a recognized keyword");
}

#---------------------------------------------------------------------
# Functions
#---------------------------------------------------------------------

#
# Store a message in the message array
#
sub report {
    my ($msg, $exval) = @_;
    return push @reports, [ $msg, $exval ];
}

#
# Give an error and exit with unknown state
#
sub unknown_error {
    my $msg = shift;
    print "ERROR: $msg\n";
    exit $E_UNKNOWN;
}

#
# Read the blacklist option and return a hash containing the
# blacklisted components
#
sub get_blacklist {
    my @bl = ();
    my @blacklist = ();

    if (scalar @{ $opt{blacklist} } >= 0) {
	foreach my $black (@{ $opt{blacklist} }) {
	    my $tmp = q{};
	    if (-f $black) {
		open my $BL, '<', $black
		  or do { report('other', "Couldn't open blacklist file $black: $!", $E_UNKNOWN)
			    and return {} };
		$tmp = <$BL>;
		close $BL;
		chomp $tmp;
	    }
	    else {
		$tmp = $black;
	    }
	    push @bl, $tmp;
	}
    }

    return [] if $#bl < 0;

    # Parse blacklist string, put in hash
    foreach my $black (@bl) {
	push @blacklist, split m{,}xms, $black;
    }

    return \@blacklist;
}

#
# Find bonding interfaces using sysfs
#
sub find_bonding_sysfs {
    my $sysdir       = '/sys/class/net';
    my $masters_file = "$sysdir/bonding_masters";
    my @bonds        = ();
    my %bonding      = ();

    if (! -f $masters_file) {
	return {};
    }

    # get bonding masters
    open my $MASTER, '<', $masters_file
      or unknown_error("Couldn't open $masters_file: $!");
    @bonds = split m{\s+}xms, <$MASTER>;
    close $MASTER;

    foreach my $bond (@bonds) {

	# get bonding mode
	open my $MODE, '<', "$sysdir/$bond/bonding/mode"
	  or unknown_error("ERROR: Couldn't open $sysdir/$bond/bonding/mode: $!");
	my ($mode, $nr) = split m/\s+/xms, <$MODE>;
	close $MODE;
	$bonding{$bond}{mode} = "mode=$nr ($mode)";

	# get slaves
	my @slaves = ();
	open my $SLAVES, '<', "$sysdir/$bond/bonding/slaves"
	  or unknown_error("Couldn't open $sysdir/$bond/bonding/slaves: $!");
	@slaves = split m/\s+/xms, <$SLAVES>;
	close $SLAVES;

	# get active slave
	open my $ACTIVE, '<', "$sysdir/$bond/bonding/active_slave"
	  or unknown_error("Couldn't open $sysdir/$bond/bonding/active_slave: $!");
	$bonding{$bond}{active} = <$ACTIVE>;
	close $ACTIVE;
	if (defined $bonding{$bond}{active}) {
	    chop $bonding{$bond}{active};
	}

	# get primary slave
	open my $PRIMARY, '<', "$sysdir/$bond/bonding/primary"
	  or unknown_error("Couldn't open $sysdir/$bond/bonding/primary: $!");
	$bonding{$bond}{primary} = <$PRIMARY>;
	close $PRIMARY;
	if (defined $bonding{$bond}{primary}) {
	    chop $bonding{$bond}{primary};
	}

	# get slave status
	foreach my $slave (@slaves) {
	    open my $STATE, '<', "$sysdir/$bond/lower_$slave/operstate"
	      or unknown_error("Couldn't open $sysdir/$bond/lower_$slave/operstate: $!");
	    chop($bonding{$bond}{slave}{$slave} = <$STATE>);
	    close $STATE;
	}

	# get bond state
	open my $BSTATE, '<', "$sysdir/$bond/operstate"
	  or unknown_error("Couldn't open $sysdir/$bond/operstate: $!");
	chop($bonding{$bond}{status} = <$BSTATE>);
	close $BSTATE;
    }

    return \%bonding;
}


#
# Find bonding interfaces using procfs (fallback, deprecated)
#
sub find_bonding_procfs {
    my $procdir = '/proc/net/bonding';
    my @bonds   = ();
    my %bonding = ();

    opendir(my $DIR, $procdir);
    @bonds = grep { m{\A bond\d+ \z}xms && -f "$procdir/$_" } readdir $DIR;
    closedir $DIR;

    if ($#bonds == -1) {
	return {};
    }

    foreach my $b (@bonds) {
	my $slave = undef;
	open my $BOND, '<', "$procdir/$b"
	  or unknown_error("Couldn't open $procdir/$b: $!");
	while (<$BOND>) {
	    # get bonding mode
	    if (m{\A Bonding \s Mode: \s (.+) \z}xms) {
		chop($bonding{$b}{mode} = $1);
	    }
	    # get slave
	    elsif (m{\A Slave \s Interface: \s (.+) \z}xms) {
		chop($slave = $1);
	    }
	    # get slave and bonding status
	    elsif (m{\A MII \s Status: \s (.+) \z}xms) {
		if (defined $slave) {
		    chop($bonding{$b}{slave}{$slave} = $1);
		}
		else {
		    chop($bonding{$b}{status} = $1);
		}
	    }
	    # get primary slave
	    elsif (m{\A Primary \s Slave: \s (.+) \z}xms) {
		chop($bonding{$b}{primary} = $1);
	    }
	    # get active slave
	    elsif (m{\A Currently \s Active \s Slave: \s (.+) \z}xms) {
		chop($bonding{$b}{active} = $1);
	    }
	}
    }

    return \%bonding;
}

#
# Find bonding interfaces
#
sub find_bonding {
    my $bonding = undef;

    # first try sysfs
    $bonding = find_bonding_sysfs();

    # second try procfs
    if (scalar keys %{ $bonding } == 0) {
	$bonding = find_bonding_procfs();
    }

    # if no bonding interfaces found, exit
    if (scalar keys %{ $bonding } == 0) {
	print $reverse_exitcode{$text2exit{$opt{no_bonding}}}
	  . ": No bonding interfaces found\n";
	exit $text2exit{$opt{no_bonding}};
    }

    return $bonding;
}

#
# Returns true if an interface is blacklisted
#
sub blacklisted {
    return 0 if !defined $opt{blacklist};
    my $if = shift;
    foreach $b (@blacklist) {
	if ($if eq $b) {
	    return 1;
	}
    }
    return 0;
}

#=====================================================================
# Main program
#=====================================================================


my %bonding = %{ find_bonding() };
MASTER:
foreach my $b (sort keys %bonding) {

    # If the master interface is blacklisted
    if (blacklisted($b)) {
	my $msg = sprintf 'Bonding interface %s [%s] is %s, but IGNORED',
	  $b, $bonding{$b}{mode}, $bonding{$b}{status};
	report($msg, $E_OK);
	next MASTER;
    }

    if ($bonding{$b}{status} ne 'up') {
	my $msg = sprintf 'Bonding interface %s [%s] is %s',
	  $b, $bonding{$b}{mode}, $bonding{$b}{status};
	report($msg, $E_CRITICAL);
    }
    else {
	my $slaves_are_up = 1; # flag

      SLAVE:
	foreach my $i (sort keys %{ $bonding{$b}{slave} }) {

	    # If the slave interface is blacklisted
	    if (blacklisted($i)) {
		my $msg = sprintf 'Slave interface %s [member of %s] is %s, but IGNORED',
		  $i, $b, $bonding{$b}{slave}{$i};
		report($msg, $E_OK);
		next SLAVE;
	    }

	    if ($bonding{$b}{slave}{$i} ne 'up') {
		$slaves_are_up = 0;  # not all slaves are up
		my $msg = sprintf 'Bonding interface %s [%s]: Slave %s is %s',
		  $b, $bonding{$b}{mode}, $i, $bonding{$b}{slave}{$i};
		report($msg, $E_WARNING);
	    }
	}
	if ($slaves_are_up) {
	    my %slave = map { $_ => q{} } keys %{ $bonding{$b}{slave} };
	    foreach my $s (keys %slave) {
		if (defined $bonding{$b}{primary} and $bonding{$b}{primary} eq $s) {
		    $slave{$s} .= '*';
		}
		if (defined $bonding{$b}{active} and $bonding{$b}{active} eq $s) {
		    $slave{$s} .= '!';
		}
	    }
	    if (scalar keys %slave == 1) {
		my @slaves = keys %slave;
		my $msg = sprintf 'Bonding interface %s [%s] has only one slave (%s)',
		  $b, $bonding{$b}{mode}, $slaves[0];
		report($msg, $E_WARNING);
	    }
	    elsif (scalar keys %slave == 0) {  # FIXME: does this ever happen?
		my $msg = sprintf 'Bonding interface %s [%s] has zero slaves!',
		  $b, $bonding{$b}{mode};
		report($msg, $E_CRITICAL);
	    }
	    else {
		my @slaves = map { $_ . $slave{$_} } sort keys %slave;
		my $msg = sprintf 'Interface %s is %s: %s, %d slaves: %s',
		  $b, $bonding{$b}{status}, $bonding{$b}{mode},
		    scalar @slaves, join q{, }, @slaves;
		report($msg, $E_OK);
	    }
	}
    }
}

# Counter variable
my %nagios_level_count
  = (
     'OK'       => 0,
     'WARNING'  => 0,
     'CRITICAL' => 0,
     'UNKNOWN'  => 0,
    );

# holds only ok messages
my @ok_reports = ();

my $c = 0;
ALERT:
foreach (sort {$a->[1] < $b->[1]} @reports) {
    my ($msg, $level) = @{ $_ };
    $nagios_level_count{$reverse_exitcode{$level}}++;

    if ($level == $E_OK && !$opt{verbose}) {
	push @ok_reports, $msg;
	next ALERT;
    }

    # Prefix with nagios level if specified with option '--state'
    $msg = $reverse_exitcode{$level} . ": $msg" if $opt{state};

    # Prefix with one-letter nagios level if specified with option '--short-state'
    $msg = (substr $reverse_exitcode{$level}, 0, 1) . ": $msg" if $opt{shortstate};

    ($c++ == 0) ? print $msg : print $linebreak, $msg;
}

# Determine our exit code
my $exit_code = $E_OK;
if ($nagios_level_count{UNKNOWN} > 0)  { $exit_code = $E_UNKNOWN;  }
if ($nagios_level_count{WARNING} > 0)  { $exit_code = $E_WARNING;  }
if ($nagios_level_count{CRITICAL} > 0) { $exit_code = $E_CRITICAL; }

# Print OK messages
if ($exit_code == $E_OK && !$opt{verbose}) {
    foreach my $msg (@ok_reports) {
	# Prefix with nagios level if specified with option '--state'
	$msg = "OK: $msg" if $opt{state};

	# Prefix with one-letter nagios level if specified with option '--short-state'
	$msg = "O: $msg" if $opt{shortstate};

	($c++ == 0) ? print $msg : print $linebreak, $msg;
    }
}

print "\n";

# Exit with proper exit code
exit $exit_code;


# Man page created with:
#
#  pod2man -s 3pm -r "`./check_linux_bonding -V | head -n 1`" -c 'Nagios plugin' check_linux_bonding check_linux_bonding.3pm
#

__END__

=head1 NAME

check_linux_bonding - Nagios plugin for checking the status of bonded
network interfaces (masters and slaves) on Linux servers.

=head1 SYNOPSIS

check_linux_bonding [I<OPTION>]...

=head1 DESCRIPTION

check_linux_bonding is a plugin for the Nagios monitoring software
that checks bonding interfaces on Linux. The plugin is fairly simple
and will report any interfaces that are down (both masters and
slaves). It will also alert you of bonding interfaces with only one
slave, since that usually points to a misconfiguration. If no bonding
interfaces are detected, the plugin will exit with an OK value
(modifiable with the C<--no-bonding> option). It is therefore safe to
run this plugin on all your Linux machines:

  $ ./check_linux_bonding
  OK: No bonding interfaces found

The plugin will first try to use the sysfs (/sys) filesystem to detect
bonding interfaces. If that does not work, i.e. the kernel or bonding
module is too old for the necessary files to exist, the plugin will
use procfs (/proc) as a fallback. The plugin supports an unlimited
number of bonding interfaces.

In the OK output, the plugin will indicate which of the slaves is
active with an exclamation mark C<!>, if applicable. If one of the
slaves is configured as primary, this is indicated with an asterisk
C<*>:

  $ ./check_linux_bonding
  Interface bond0 is UP: mode=1 (active-backup), 2 slaves: eth0*, eth1!

=head1 OPTIONS

=over 4

=item -b, --blacklist I<STRING> or I<FILE>

Blacklist one or more interfaces. The option can be specified multiple
times. If the argument is a file, the file is expected to contain a
single line with the same syntax, i.e.:

  interface1,interface2,...

Examples:

  check_linux_bonding -b bond1 -b eth1
  check_linux_bonding -b bond1,eth1
  check_linux_bonding -b /etc/check_linux_bonding.black

=item -n, --no-bonding I<STRING>

This option lets you specify the return value of the plugin if no
bonding interfaces are found. The option expects C<ok>, C<warning>,
C<critical> or C<unknown> as the argument. Default is C<ok> if the
option is not present.

=item -t, --timeout I<SECONDS>

The number of seconds after which the plugin will abort. Default
timeout is 5 seconds if the option is not present.

=item -s, --state

Prefix each alert with its corresponding service state (i.e. warning,
critical etc.). This is useful in case of several alerts from the same
monitored system.

=item --short-state

Same as the B<--state> option above, except that the state is
abbreviated to a single letter (W=warning, C=critical etc.).

=item --linebreak=I<STRING>

check_linux_bonding will sometimes report more than one line, e.g. if
there are several alerts. If the script has a TTY, it will use regular
linebreaks. If not (which is the case with NRPE) it will use HTML
linebreaks. Sometimes it can be useful to control what the plugin uses
as a line separator, and this option provides that control.

The argument is the exact string to be used as the line
separator. There are two exceptions, i.e. two keywords that translates
to the following:

=over 4

=item B<REG>

Regular linebreaks, i.e. "\n".

=item B<HTML>

HTML linebreaks, i.e. "<br/>".

=back

This is a rather special option that is normally not needed. The
default behaviour should be sufficient for most users.

=item -v, --verbose

Verbose output. Will report status on all bonding interfaces,
regardless of their alert state.

=item -h, --help

Display help text.

=item -m, --man

Display man page.

=item -V, --version

Display version info.

=head1 DIAGNOSTICS

The option C<--verbose> (or C<-v>) can be specified to display all
bonding interfaces.

=head1 DEPENDENCIES

This plugin depends on sysfs and fallbacks to procfs. Without these
filesystems the plugin will not find any bonding interfaces.

=head1 EXIT STATUS

If no errors are discovered, a value of 0 (OK) is returned. An exit
value of 1 (WARNING) signifies one or more non-critical errors, while
2 (CRITICAL) signifies one or more critical errors.

The exit value 3 (UNKNOWN) is reserved for errors within the script,
or errors getting values sysfs or procfs.

=head1 AUTHOR

Written by Trond H. Amundsen <t.h.amundsen@usit.uio.no>

=head1 BUGS AND LIMITATIONS

None known at present.

=head1 INCOMPATIBILITIES

The plugin is only compatible with the Linux operating system.

=head1 REPORTING BUGS

Report bugs to <t.h.amundsen@usit.uio.no>

=head1 LICENSE AND COPYRIGHT

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see L<http://www.gnu.org/licenses/>.

=head1 SEE ALSO

L<http://folk.uio.no/trondham/software/check_linux_bonding.html>

=cut
