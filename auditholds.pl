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
my $VERSION    = qq{0.4};




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

 -e: Print exhaustive report, that is, all multi-callnum titles with holds
     and multi-callnum titles with holds with callnums with no visible copies.
 -t: Test script. Doesn't remove temporary files so they can be reviewed.
 -v: Ignore obvious volume situations, that is, drop titles that contain
     callnums related to volumes.
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
    my $opt_string = 'etvx';
    getopts( "$opt_string", \%opt ) or usage();
    usage() if ( $opt{'x'} );
    printf STDERR "Test mode active. Temp files will not be deleted. Please clean up '%s' when done.\n", $TEMP_DIR if ( $opt{'t'} );
}

# Tests if a line ('flex_key|callnum') looks like a multi-volume title.
# param:  line as above.
# return: 1 if the title is a multi-volume hold and 0 if title is not or the results are unclear.
sub is_multi_volume_title( $ )
{
	my $line = shift;
	return 1 if ( $line =~ m/\s+(19|20)\d{2}$/ ); # lines for multivolume sets typically end with a year.
	return 1 if ( $line =~ m/\s+(v|V|bk|BK)\.\d{1,}$/ ); # lines for multivolume sets typically end with v.##.
	return 0;
}

# Formats and prints a report of findings.
# param:  String header message.
# param:  result string from API calls: '999407|55|DVD NOT AVAILABLE|0|'.
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
		next if ( is_multi_volume_title( $line ) and $opt{'v'} );
		my ( $tcn, $callnum ) = split '\|', $line;
		format STDOUT =
@>>>>>>>>>>> @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
$tcn, $callnum
.
		write STDOUT;
	}
}

init();

# This is a description of the following selection broken down by pipe boundary.
# From the HOLD table, select all active non-available holds and output the cat key.
# sort the keys.
# unique the keys.
# select from the CALLNUM table all the entries based on supplied cat keys and output the callnum key, callnum, and visible items.
my $results = `selhold -j"ACTIVE" -a'N' -oC 2>/dev/null | sort | uniq | selcallnum -iC -oNDz 2>/dev/null`;
my $master_list = create_tmp_file( "audithold_callnum_keys", $results );
# So now we have all the callnum keys, callnums, and visible items.
# This is a description of the following selection broken down by pipe boundary.
# cat the list of call nums which looks like '997099|38|Teen fiction - Series H PBK|0|'
# Take input into pipe.pl and dedup on the callnum and cat key in that order. This gives a list of cat keys and unique callnumbers.
# Use the results and sort by cat key and callnum, then dedup again this time on cat key and output a count of dedups delimited by a '|'.
# Take that output and only display the lines that have a count greater than one, that is, output the cat keys that have more than
# 1 different callnumbers.
$results = `cat "$master_list" | pipe.pl -d'c2,c0' | pipe.pl -s'c1,c3' -d'c0' -A -P | pipe.pl -C'c0:gt1' -o'c1'`;
my $cat_key_list = create_tmp_file( "audithold_cat_keys", $results );
# Tidy up the master list, if there is one.
unlink $master_list if ( -s $master_list and ! $opt{'t'} );
if ( -s $cat_key_list )
{
	# This is a description of the following selection broken down by pipe boundary.
	# cat the list of cat keys selected above.
	# select from CALLNUM all cat keys, output call number key, call number, and count of visible items under the callnum.
	# 999466|85|TEEN LOR|1|
	# 999466|84|Teen fiction - Series I PBK|1|
	# 999524|145|TEEN SAE|1|
	# 999524|53|Teen fiction S|vPBK|0|
	# 999524|147|Teen fiction S PBK|1|
	# 999407|59|DVD 617.58204 BOW|1|
	# 999407|55|DVD NOT AVAILABLE|0|
	$results = `cat "$cat_key_list" | selcallnum -iC -oNDz 2>/dev/null | pipe.pl  -d'c0,c2' | pipe.pl -s'c0'`;
	my $candidate_callnums = create_tmp_file( "audithold_candidate_callnums", $results );
	if ( -s $candidate_callnums )
	{
		my $count = `cat "$cat_key_list" | wc -l | pipe.pl -t'c0'`;
		chomp $count;
		my $header = sprintf "%d multi-callnum titles with holds.", $count;
		# The first report will output all titles with holds that have multiple callnums.
		$results = `cat "$candidate_callnums" | selcatalog -iC -oFS 2>/dev/null | pipe.pl -t'c0' -o'c0,c2' -s'c0'`;
		print_report( $header, $results ) if ( $opt{'e'} );
		# else just print the report of those titles with call nums with no visible items.
		my $zero_count = `cat "$candidate_callnums" | pipe.pl -C'c3:eq0' | wc -l | pipe.pl -t'c0'`;
		chomp $zero_count;
		$header = sprintf "%d multi-callnum titles with hold, %d with 0 visible copies.", $count, $zero_count;
		# This is a description of the following selection broken down by pipe boundary.
		# cat the list of cat keys selected above.
		# select from CATALOG from input of cat keys, output the TCN and `o785243323        |55|DVD NOT AVAILABLE|0|`.
		# take the input trim the flex key, output flex key and callnum if the number of visible items under callnum is 0.
		$results = `cat "$candidate_callnums" | selcatalog -iC -oFS 2>/dev/null | pipe.pl -t'c0' -o'c0,c2' -C'c3:eq0' -s'c0'`;
		print_report( $header, $results );
		# Now I want to see a list of all the titles, with the different call numbers under it.
		$results = `cat "$cat_key_list" | selcatalog -iC -oCF 2>/dev/null | selcallnum -iC -oSD 2>/dev/null | pipe.pl -t'c0' -d'c1,c0' | pipe.pl -s'c0'`;
		print_report( "", $results );
		# Tidy up the master list, if there is one.
		unlink $cat_key_list if ( -s $cat_key_list and ! $opt{'t'} );
		unlink $candidate_callnums if ( -s $candidate_callnums and ! $opt{'t'} );
	}
	else
	{
		printf STDERR "No call numbers with 0 visible items found.\n";
	}
}
else
{
	printf STDERR "No problems detected.\n";
	exit 0;
}
# EOF
