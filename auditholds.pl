#!/usr/bin/perl -w
####################################################
#
# Perl source file for project auditholds 
# Purpose:
# Method:
#
# Produces a report of possible hold problems such as orphaned holds.
#    Copyright (C) 2015  Andrew Nisbet
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA 02110-1301, USA.
#
# Author:  Andrew Nisbet, Edmonton Public Library
# Created: Wed Sep 9 11:29:32 MDT 2015
# Rev: 
#          0.3 Sept. 11, 2015 - Improve reporting.
#
####################################################

use strict;
use warnings;
use vars qw/ %opt /;
use Getopt::Std;

# Environment setup required by cron to run script because its daemon runs
# without assuming any environment settings and we need to use sirsi's.
###############################################
# *** Edit these to suit your environment *** #
$ENV{'PATH'}  = qq{:/s/sirsi/Unicorn/Bincustom:/s/sirsi/Unicorn/Bin:/usr/bin:/usr/sbin};
$ENV{'UPATH'} = qq{/s/sirsi/Unicorn/Config/upath};
###############################################
my $TEMP_DIR   = `getpathname tmp`;
chomp $TEMP_DIR;
my $TIME       = `date +%H%M%S`;
chomp $TIME;
my $DATE       = `date +%m/%d/%Y`;
chomp $DATE;
my $VERSION    = qq{0.3};




#
# Message about this program and how to use it.
#
sub usage()
{
    print STDERR << "EOF";

	usage: $0 [-x]
This script reports problems with holds, specifically orphaned holds.
An orphaned hold is one that exists on a call number that has no visible 
item copies.

 -x: This (help) message.

example: $0 -x
Version: $VERSION
EOF
    exit;
}

# Writes data to a temp file and returns the name of the file with path.
# param:  unique name of temp file, like master_list, or 'hold_keys'.
# param:  data to write to file.
# return: name of the file that contains the list.
sub create_tmp_file( $$ )
{
	my $name    = shift;
	my $results = shift;
	my $master_file = "$TEMP_DIR/$name.$TIME";
	open FH, ">$master_file" or die "*** error opening '$master_file', $!\n";
	my @list = split '\n', $results;
	foreach my $line ( @list )
	{
		print FH "$line\n";
	}
	close FH;
	return $master_file;
}

# Kicks off the setting of various switches.
# param:  
# return: 
sub init
{
    my $opt_string = 'x';
    getopts( "$opt_string", \%opt ) or usage();
    usage() if ( $opt{'x'} );
}

# Formats and prints a report of findings.
# param:  String header message.
# param:  result string from API calls: 'TCN| call number | visible copies'.
# return: <none>
sub print_report( $$ )
{
	printf "\n";
	printf "   Titles with problematic holds report, %s\n", $DATE;
	printf "   %s\n", shift;
	my $leader_tcn = `echo "TCN" | pipe.pl -p'c0:+12'`;
	my $leader_cno = `echo "Call Number" | pipe.pl -p'c1:-32'`;
	chomp $leader_tcn;
	chomp $leader_cno;
	printf "%s %s\n", $leader_tcn, $leader_cno;
	printf "  -------------------------------------------------\n";
	my @lines = split '\n', shift;
	while ( @lines )
	{
		my $line = shift @lines;
		my ( $tcn, $callnum ) = split '\|', $line;
		format STDOUT =
@>>>>>>>>>>> @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
$tcn, $callnum
.
		write STDOUT;
	}
}

init();


# Output all cat keys for titles with holds that have 2 or more distinct callnums. 
my $results = `selhold -j"ACTIVE" -a"N" -t'T' -oN 2>/dev/null | sort | uniq | selcallnum -iN -oCD 2>/dev/null | pipe.pl -dc1 -A | pipe.pl -W"\\s+" -C'c0:ge2' -o'c1' -s'c1'`;
my $master_list = create_tmp_file( "cat_keys", $results );
if ( -s $master_list )
{
	$results = `cat "$master_list" | selcatalog -iC -oCF 2>/dev/null | selcallnum -iC -oNDzS 2>/dev/null | pipe.pl -dc1 -o'c4,c2,c3' -C'c3:eq0' | pipe.pl -sc0 -dc1 -tc0`;
	my $non_visible_callnums = create_tmp_file( "non_visible_callnums", $results );
	if ( -s $non_visible_callnums )
	{
		my $count = `cat "$non_visible_callnums" | wc -l`;
		chomp $count;
		my $header = sprintf "%d call numbers with hold issues.", $count;
		$results = `cat "$non_visible_callnums"`;
		print_report( $header, $results );
		unlink $non_visible_callnums;
	}
	else
	{
		printf STDERR "No call numbers with 0 visible items found.\n";
	}
	unlink $master_list;
}
else
{
	printf STDERR "*** error creating temp file '$master_list'.\n";
	exit 0;
}
# EOF
