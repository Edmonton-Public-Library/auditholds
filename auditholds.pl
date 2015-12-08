#!/usr/bin/perl -w
######################################################################
#
# Perl source file for project auditholds 
# Purpose: Identify titles with potentially problem holds.
# Method:  Symphony API (v. 3.4.3).
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
#          0.6.w Dec. 03, 2015 - Add further refinement and output of discarded items with holds.
#          0.6.v Oct. 22, 2015 - Fixed error reading empty file if no orphaned holds found.
#          0.6.u Oct. 20, 2015 - reporting.
#          0.6.t Oct. 9, 2015 - Re-factored audit orphaned holds.
# TODO:    Fix message below.
# bash-3.2$ ./auditholds.pl -oV
# Orphaned holds: no errors detected.
#    Orphaned holds report, 11/06/2015
#   -------------------------------------------------
# cat: cannot open /tmp/audithold_o03.144156
#
#######################################################################

use strict;
use warnings;
use vars qw/ %opt /;
use Getopt::Std;

# Algorithm: 
# Select titles with holds that have callnums with no visible copies.

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
my $DIFF               = "$BINCUSTOM/diff.pl";
my $VERSION            = qq{0.6.w};

#
# Message about this program and how to use it.
#
sub usage()
{
    print STDERR << "EOF";

	usage: $0 [-fiotvx]
This script reports that detail problems with multi-volume titles with holds on non-visible items,
stalled holds on format variations, and orphaned holds. Orphaned holds are holds that are stuck on
a non-visible item in a call number range that differs from the rest of the title. These holds stall
while other customers continue to advance in hold ranking. In extreme cases staff report that there
are items in stacks but dozens of holds in the queue.

 -f: Produce report of holds stalled on titles because of variation of format PBK vs. TRADE-PBK etc.
 -i: Break out items of concern.
 -o: Produce report of titles with orphaned holds.
 -t: Test mode. Doesn't remove any temporary files so you can debug stages of selection.
 -v: Produce report of holds stalled on titles because the title have volumes that have no visible items.
 -V: Verbose reporting. Reports complete item information, otherwise just counts are reported.
 -x: This (help) message.

example: 
 $0 -x
Give counts of problems on titles with volumes.
 $0 -v
Give counts of problems on titles with volumes, but report all the call nums.
 $0 -vV
Report potential orphan holds, show call nums, and items that are problematic.
 $0 -oVi
Version: $VERSION
EOF
    exit;
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
				unlink $file;
			}
		}
	}
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
	# Return just the file name if there are no results to report.
	return $master_file if ( ! $results );
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

# Counts the number of lines in a given file. If the file doesn't exist count returned is 0.
# param:  name of the file to open and count.
sub count_lines( $ )
{
	my $master_file = shift;
	open FH, "<$master_file" or die "*** error opening '$master_file', $!\n";
	my $count = 0;
	while (<FH>)
	{
		$count++;
	}
	close FH;
	return $count;
}

# Creates a hash reference of the pipe delimited data read from a file.
# param:  String name of fully qualified path to the file where data will be read from.
# param:  List reference of integer that are the 0 based indexes to the columns that make up the key to an entry.
#         The key will be made from only existing columns. If no indexes are selected the function issues
#         an error message and then returns an empty hash reference.
# param:  List reference of integers that are the 0 based indexes to the columns that make up the value to an entry.
#         If the list is empty the value '1' is stored as a default value and a warning message is issued.
# return: Reference to the hash created by the process which will be empty if anything fails.
sub read_file_into_hash_reference( $$$ )
{
	my $hash_ref = {};
	my $file     = shift;
	my $indexes  = shift;
	my $values   = shift;
	if ( ! -s $file )
	{
		printf STDERR "** error can't make hash table from missing or empty file '%s'!\n", $file;
		return $hash_ref;
	}
	if ( ! scalar @{$indexes} )
	{
		printf STDERR "** error no indexes defined for hash key\n", $file;
		return $hash_ref;
	}
	if ( ! scalar @{$values} )
	{
		printf STDERR "* warning no values defined setting values to default of 1.\n", $file;
	}
	open IN, "<$file" or die "** error opening $file, $!\n";
	while (<IN>)
	{
		my $line = $_;
		chomp $line;
		my @cols = split '\|', $line;
		my $key = '';
		my $value = '';
		foreach my $index ( @{$indexes} )
		{
			$key .= $cols[ $index ] . "|" if ( $cols[ $index ] );
		}
		foreach my $index ( @{$values} )
		{
			$value .= $cols[ $index ] . "|" if ( $cols[ $index ] );
		}
		$value = "1" if ( ! $value );
		$hash_ref->{"$key"} = "$value" if ( $key );
	}
	close IN;
	return $hash_ref;
}

# Convert the data structure (hash table reference) in which all the keys have similar
# values into a hash table (reference) that has as its keys, the values from the 
# original table, but the values are a list (reference) of keys from the original table.
# Example:
# Given a hash ref like:
# hash_ref{'111'} = 'abc'
# hash_ref{'222'} = 'abc'
# hash_ref{'333'} = 'abc'
# Create a new hash that looks like
# hash_ref_prime{'abc'} =  ('111', '222', '333')
# param:  hash reference of keys and values.
# return: new hash reference.
sub enlist_values( $ )
{
	my $hash_in = shift;
	my $hash_out= {};
	foreach my $key ( keys %$hash_in )
	{
		my $new_key = $hash_in->{ $key };
		my $value_list_ref = ();
		if ( exists $hash_out->{ $new_key } )
		{
			$value_list_ref = $hash_out->{ $new_key };
		}
		push @{ $value_list_ref }, $key;
		$hash_out->{ $new_key } = $value_list_ref;
	}
	return $hash_out;
}

# Reports counts for each files.
# param:  title string of the file contents.
# param:  name of the file.
# return: <none>
sub report_file_counts( $$ )
{
	my $title = shift;
	my $file  = shift;
	if ( -s $file )
	{
		printf "\n%s: initial error(s) detected: %d\n", $title, count_lines( $file );
	}
	else
	{
		printf "\n%s: no errors detected.\n", $title;
	}
}

# Formats and prints a report of findings, TCN CallNum and optional items.
# param:  String header message.
# param:  result string from API calls. Consumes data like:
#     '1000044|60|Easy readers M PBK|0|epl000001934|'
#     Outputs: flex key | call num and optional IDs if -i selected.
# param:  Hash reference of items with callnum key values i.e.: '1000216|46|'.
# return: <none>
sub print_report( $$$ )
{
	printf "\n";
	printf "   %s, %s\n", shift, $DATE;
	printf "  -------------------------------------------------\n";
	my $file = shift;
	if ( ! -s $file )
	{
		printf STDERR "no problems found.\n";
		return;
	}
	my $items= shift;
	# Get rid of the initial call num for output, 
	my $results = `cat "$file" | "$PIPE" -o'c4,c2,c0,c1' | "$PIPE" -s'c0'`;
	my @lines = split '\n', $results;
	while ( @lines )
	{
		my $line = shift @lines;
		chomp $line;
		my ( $tcn, $callnum, $cat_key, $sequence ) = split '\|', $line;
		# printf STDEERR "%11s %32s %14s, %10s\n", $tcn, $callnum, $cat_key, $sequence;
		printf "%s, %s\n", $tcn, $callnum;
		if ( $opt{'i'} )
		{
			# Our look up key is found in the cat key and sequence. We use them to look up items in the items hash_reference (param 3).
			my $key = sprintf "%s|%s|", $cat_key, $sequence;
			my $list_of_items = $items->{"$key"};
			foreach my $item_line ( @{ $list_of_items } )
			{
				my ( $item, $location ) = split '\|', $item_line;
				printf "   %14s %10s\n", $item, $location;
			}
		}
	}
}

# Kicks off the setting of various switches.
# param:  
# return: 
sub init
{
	my $opt_string = 'fiotvVx';
	getopts( "$opt_string", \%opt ) or usage();
	usage() if ( $opt{'x'} );
	if ( ! -s $PIPE )
	{
		printf STDERR "*** error, required application '%s' not found.\n", $PIPE;
		exit 0;
	}
	# TODO: fix to account for the differences between the two item types. You are looking for call numbs where 
	# all of the items under a call num range have 0 visible copies.
	if ( $opt{'f'} )
	{
		# Select all the titles from the hold table that have call numbers with zero visible items.
		my $results = `selhold -j"ACTIVE" -a'N' -t'T' -oC 2>/dev/null | "$PIPE" -d'c0' | selcallnum -iC -z"=0" -oNDz 2>/dev/null`;
		my $cat_keys = create_tmp_file( "audithold_f00", $results );
		# Produces:
		# 1000047|38|Easy readers T PBK|0|
		# 1000047|43|Easy readers T PBK|0|
		# 1000051|11|Easy readers L TradePBK|0|
		# We need to get titles with more than 1 hold, with zero visible items under a call number.
		$results = `cat "$cat_keys" | "$PIPE" -g'c2:PBK' -d'c2,c0'`;
		my $format_callnum_keys = create_tmp_file( "audithold_f01", $results );
		report_file_counts( "Holds stuck on format", $format_callnum_keys );
		print_report( "Holds stuck on item format report", $format_callnum_keys, "" ) if ( $opt{'V'} );
	}
	# Orphaned holds; holds for titles that are not multi-volume titles, but have callnumbers with variances in holds counts relative to the title.
	if ( $opt{'o'} )
	{
		my $results = `selhold -j"ACTIVE" -a'N' -t'T' -oC 2>/dev/null | "$PIPE" -d'c0' | selcallnum -iC -z"=0" -oC 2>/dev/null | "$PIPE" -d'c0'`;
		my $cat_keys = create_tmp_file( "audithold_o00", $results );
		my $differences = '';
		# Test if the file exists because sometimes theres just aren't any orphaned holds.
		if ( -s $cat_keys )
		{
			# To get the holds on a title do this:
			# 1413866|3|
			$results = `cat "$cat_keys" | selcatalog -iC -oCh 2>/dev/null`;
			my $hold_title_counts = create_tmp_file( "audithold_o01", $results );
			# This will select all the items under a cat key with holds and count the holds on each item.
			# 1413866|1|
			$results = `cat "$cat_keys" | selhold -iC -a'N' -t'T' -j"ACTIVE" -oI 2>/dev/null | "$PIPE" -d'c0' -A -P | "$PIPE" -o'c1,c0' -P`;
			my $hold_item_counts = create_tmp_file( "audithold_o02", $results );
			# Now diff the two files and merge the hold counts.
			$results = `echo "$hold_title_counts not $hold_item_counts" | "$DIFF" -e'c0,c1' -f'c0,c1'`;
		}
		$differences = create_tmp_file( "audithold_o03", $results );
		# Now weed out the items that are intransit, they create a false positive result.# But we don't want in transit items because they produce false positives.
		# selitem -iI -m"~INTRANSIT" -oI 2>/dev/null |
		report_file_counts( "Orphaned holds", $differences );
		print_report( "Orphaned holds report", $differences, "" ) if ( $opt{'V'} );
	}
	if ( $opt{'v'} )
	{
		# Select all the titles from the hold table that have call numbers with zero visible items.
		printf STDERR "creating master list.\n";
		my $results = `selhold -j"ACTIVE" -a'N' -t'T' -oC 2>/dev/null | "$PIPE" -d'c0' | selcallnum -iC -z"=0" -oNDz 2>/dev/null`;
		my $master_list = create_tmp_file( "audithold_master", $results );
		printf STDERR "refining master list.\n";
		$results = `cat "$master_list" | selcatalog -iC -oCSF 2>/dev/null | "$PIPE" -t'c4' -P`;
		$master_list = create_tmp_file( "audithold_master", $results );
		# Produces:
		# 1000066|36|Picture books D PBK|0|epl000001956
		
		### Here we create two tables; one for the call num key and one for the item ids callnum key values.
		my @key_indexes     = (4,2);
		my @value_indexes   = (0,1);
		my $master_hash_ref = {};
		$master_hash_ref    = read_file_into_hash_reference( $master_list, \@key_indexes, \@value_indexes );
		# $master_hash_ref->{'epl000001956|Picture books D PBK|'} = '1000066|36|'
		
		
		printf STDERR "distilling items for master list.\n";
		$results = `cat "$master_list" | selitem -iN -oNBm 2>/dev/null | "$PIPE" -t'c2'`;
		my $items_list = create_tmp_file( "audithold_items", $results );
		# Produces:
		# 1000066|36|31221101011349|DISCARD
		$master_hash_ref   = {};
		@key_indexes       = (2,3);
		@value_indexes     = (0,1);
		my $items_hash_ref = {};
		$items_hash_ref    = read_file_into_hash_reference( $items_list, \@key_indexes, \@value_indexes );
		# $items_hash_ref->{'31221101011349|DISCARD|'} = '1000066|36|'
		
		# Now using enlist to make lists of items for each call num key.
		$items_hash_ref = enlist_values( $items_hash_ref );
		# $items_hash_ref->{'1000066|36|'} = ('31221101011349|DISCARD|', '...')
		
		# From this list we can weed out volumes that have no visible copies with:
		$results = `cat "$master_list" | "$PIPE" -g'c2:(v|V)\\.' -d'c2,c0' | "$PIPE" -s'c0' -U`;
		my $volume_list = create_tmp_file( "audithold_volumes", $results );
		report_file_counts( "volumes", $volume_list );
		print_report( "Volumes with non-visible items report", $volume_list, $items_hash_ref );
		$results = `cat "$master_list" | "$PIPE" -g'c2:\\s+(19|20)\\d\\d' -d'c2,c0' | "$PIPE" -s'c0' -U`;
		my $annuals_list = create_tmp_file( "audithold_annuals", $results );
		report_file_counts( "annuals", $annuals_list );
		print_report( "Annuals with non-visible items report", $annuals_list, $items_hash_ref );
		$results = `cat "$master_list" | "$PIPE" -g'c2:(bk|BK)\.' -d'c2,c0' | "$PIPE" -s'c0' -U`;
		my $bk_list = create_tmp_file( "audithold_books", $results );
		report_file_counts( "book volumes", $bk_list );
		print_report( "Multi-volume books with non-visible items report", $bk_list, $items_hash_ref );
		$results = `cat "$master_list" | "$PIPE" -g'c2:\\s+(p|P)(t|T)(s|S)?\\.' -d'c2,c0' | "$PIPE" -s'c0' -U`;
		my $sets_list = create_tmp_file( "audithold_sets", $results );
		report_file_counts( "sets", $sets_list );
		print_report( "Sets with non-visible items report", $sets_list, $items_hash_ref );
		$results = `cat "$master_list" | "$PIPE" -g'c2:\\s+(k|K)(i|I)(t|T)' -d'c2,c0' | "$PIPE" -s'c0' -U`;
		my $kits_list = create_tmp_file( "audithold_kits", $results );
		report_file_counts( "kits", $kits_list );
		print_report( "Kits with non-visible items report", $kits_list, $items_hash_ref );
	}
}

init();

if ( $opt{'t'} )
{
	printf STDERR "Temp files will not be deleted. Please clean up '%s' when done.\n", $TEMP_DIR;
}
else
{
	clean_up();
}
# EOF
