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
#          0.5 Sept. 11, 2015 - Modularize reporting.
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
my $TEMP_DIR           = `getpathname tmp`;
chomp $TEMP_DIR;
my $TIME               = `date +%H%M%S`;
chomp $TIME;
my $DATE               = `date +%m/%d/%Y`;
chomp $DATE;
my @CLEAN_UP_FILE_LIST = (); # List of file names that will be deleted at the end of the script if ! '-t'.
my $BINCUSTOM          = `getpathname bincustom`;
chomp $BINCUSTOM;
my $PIPE               = "$BINCUSTOM/pipe.pl";
my $VERSION            = qq{0.4};

# Algorithm: 
# 

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

 -c: Ignore titles with only copy level holds.
 -e: Print exhaustive report, that is, all multi-callnum titles with holds
     and multi-callnum titles with holds with callnums with no visible copies.
 -t: Test script. Doesn't remove temporary files so they can be reviewed.
 -v: Ignore titles that contain callnums related to volumes.
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
	# Add it to the list of files to clean if required at the end.
	push @CLEAN_UP_FILE_LIST, $master_file;
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
	if ( ! -s $PIPE )
	{
		printf STDERR "*** error, required application '%s' not found.\n", $PIPE;
		exit 0;
	}
    printf STDERR "Test mode active. Temp files will not be deleted. Please clean up '%s' when done.\n", $TEMP_DIR if ( $opt{'t'} );
}

# Tests if a line ('flex_key|callnum') looks like a multi-volume title.
# param:  line as above.
# return: 1 if the title is a multi-volume hold and 0 if title is not or the results are unclear.
sub is_multi_volume_title( $ )
{
	my $line = shift;
	return 1 if ( $line =~ m/\s+(19|20)\d{2}$/ ); # lines for multivolume sets typically end with a year.
	return 1 if ( $line =~ m/\s+(v|V|bk|BK)\.\d{1,}/ ); # lines for multivolume sets typically end with v.##.
	return 1 if ( $line =~ m/\s+(p|P)(t|T)(s|S)?\.\d{1,}/ ); # lines for multivolume sets typically end with pt.##.
	return 1 if ( $line =~ m/\s+(k|K)(i|I)(t|T)\.\d{1,}/ ); # lines for multivolume kits end with pt.##.
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
	my $leader_tcn = `echo "TCN" | "$PIPE" -p'c0:+12'`;
	my $leader_cno = `echo "Call Number" | "$PIPE" -p'c1:-32'`;
	chomp $leader_tcn;
	chomp $leader_cno;
	printf "%s %s\n", $leader_tcn, $leader_cno;
	printf "  -------------------------------------------------\n";
	my @lines = split '\n', shift;
	while ( @lines )
	{
		my $line = shift @lines;
		# This deselects an individual item, but not the entire set. If one member fails the entire title should be discarded.
		# next if ( is_multi_volume_title( $line ) and $opt{'v'} );
		my ( $tcn, $callnum ) = split '\|', $line;
		format STDOUT =
@>>>>>>>>>>> @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
$tcn, $callnum
.
		write STDOUT;
	}
}

# Removes all the temp files created during running of the script.
# param:  List of all the file names to clean up.
# return: <none>
sub clean_up
{
	foreach my $file ( @CLEAN_UP_FILE_LIST )
	{
		if ( $opt{'t'} )
		{
			printf STDERR "preserving file '%s' for review.\n", $file;
		}
		else
		{
			if ( -e $file )
			{
				printf STDERR "removing '%s'.\n", $file;
				unlink $file;
			}
			else
			{
				printf STDERR "** Warning: file '%s' not found.\n", $file;
			}
		}
	}
}

# Creates a new list of candidate callnums after removing titles whose only variation of callnum is ON-ORDER.
# param:  
# return: string path of the file that contains the cat keys of titles whose only variation on callnum is ON-ORDER.
sub remove_on_order_callnums( $ )
{
	return "";
}

init();

# This is a description of the following selection broken down by pipe boundary.
# From the HOLD table, select all active non-available holds and output the cat key.
# sort the keys.
# unique the keys.
# select from the CALLNUM table all the entries based on supplied cat keys and output the callnum key, callnum, and visible items.
my $results = `selhold -j"ACTIVE" -a'N' -oCt 2>/dev/null | "$PIPE" -d'c0' | selcallnum -iC -oNDzS 2>/dev/null`;
# Produces:
# 999714|1|ON ORDER|0|T|
# 999714|12|TEEN SHU v.4|0|T|
# 999714|28|TEEN SHU v.4|1|T|
# 999714|31|TEEN SHU v.4|1|T|
# 999714|35|TEEN SHU v.4|1|T|
# 999714|36|TEEN SHU v.4|1|T|
# 999714|37|TEEN SHU v.4|1|T|
# 999714|38|TEEN SHU v.4|1|T|
my $master_list = create_tmp_file( "audithold_callnum_keys", $results );
# So now we have all the callnum keys, callnums, and visible items.
# This is a description of the following selection broken down by pipe boundary.
# cat the list of call nums which looks like '997099|38|Teen fiction - Series H PBK|0|T|'
# Take input into pipe.pl and dedup on the callnum and cat key in that order. This gives a list of cat keys and unique callnumbers.
# Use the results and sort by cat key and callnum, then dedup again this time on cat key and output a count of dedups delimited by a '|'.
# Take that output and only display the lines that have a count greater than one, that is, output the cat keys that have more than
# 1 different callnumbers.
$results = `cat "$master_list" | "$PIPE" -d'c2,c0' | "$PIPE" -s'c1,c3' -d'c0' -A -P | "$PIPE" -C'c0:gt1' -o'c1'`;
my $cat_key_list = create_tmp_file( "audithold_cat_keys", $results );
if ( -s $cat_key_list )
{
	printf STDERR "No problems detected.\n";
	clean_up();
	exit 0;
}

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
# $results = `cat "$cat_key_list" | selcallnum -iC -oNDz 2>/dev/null | pipe.pl  -d'c0,c2' | pipe.pl -s'c0'`;
# my $candidate_callnums = create_tmp_file( "audithold_candidate_callnums", $results );
# my $titles_no_orders = remove_on_order_callnums( $candidate_callnums );
# $titles_of_interest = remove_multi_volume_titles( $titles_of_interest ) if ( $opt{'v'} );
clean_up();
# EOF
