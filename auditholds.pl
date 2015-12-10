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
#          0.6.x Dec. 09, 2015 - Format hold issue reporting.
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
my $MASTER_LIST        = '';  # All functions start with the same basic selection of titles. This is the name of that file.
my $VERSION            = qq{0.6.x};

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
		# printf STDERR "<<%s %s %s, %s>>\n", $tcn, $callnum, $cat_key, $sequence;
		my $output_str = sprintf "%s, %s\n", $tcn, $callnum;
		if ( scalar keys %$items )
		{
			# Our look up key is found in the cat key and sequence. We use them to look up items in the items hash_reference (param 3).
			my $key = '';
			# Some reports (orphan) don't include a sequence number because they roll up items to a title.
			# Items won't match exact callnum keys.
			if ( $sequence )
			{
				$key = sprintf "%s|%s|", $cat_key, $sequence;
			}
			else
			{
				$key = sprintf "%s|", $cat_key;
			}
			my $list_of_items = $items->{"$key"};
			my $is_discard = 0;
			foreach my $item_line ( @{ $list_of_items } )
			{
				my ( $item, $location ) = split '\|', $item_line;
				$is_discard = 1 if ( $location =~ m/DISCARD/ );
				if ( $opt{'i'} )
				{
					$output_str .= sprintf "    %14s %10s\n", $item, $location;
				}
			}
			if ( $is_discard )
			{
				printf "* ";
			}
			else
			{
				printf "  ";  
			}
		}
		# Line ready to print.
		printf "%s", $output_str;
	}
}

# Audits hold balances across titles with different item formats. The function looks at titles that have different
# item types, but focuses on titles with holds where one or more call numbers have visible copies but 0 holds.
# param:  <none>
# return: <none>
sub audit_formats( $ )
{
	my $master_list = shift;
	# TODO: fix to account for the differences between the two item types. You are looking for call numbs where 
	# all of the items under a call num range have 0 visible copies.
	# 1000047|38|Easy readers T PBK|0|epl000001934|
	# 1000047|43|Easy readers T PBK|0|epl000001934|
	# 1000051|11|Easy readers L TradePBK|0|epl00019444|
	# We need to get titles with more than 1 hold, with zero visible items under a call number.
	my $results = `cat "$master_list" | "$PIPE" -g'c2:PBK' -d'c2,c0' -P`;
	my $format_callnum_keys = create_tmp_file( "audithold_f_all_pbk_callnums", $results );
	# 767123|30|130.973 BIR PBK|0|a767123|
	printf STDERR "distilling items for master list.\n";
	$results = `cat "$master_list" | selitem -iN -oNBm 2>/dev/null | "$PIPE" -t'c2'`;
	my $items_list = create_tmp_file( "audithold_f_items", $results );
	# Produces:
	# 1000066|36|31221101011349|DISCARD
	my @key_indexes       = (2,3);
	my @value_indexes     = (0,1);
	my $items_hash_ref = {};
	$items_hash_ref    = read_file_into_hash_reference( $items_list, \@key_indexes, \@value_indexes );
	# $items_hash_ref->{'31221101011349|DISCARD|'} = '1000066|36|'
	# Now using enlist to make lists of items for each call num key.
	$items_hash_ref = enlist_values( $items_hash_ref );
	# $items_hash_ref->{'1000066|36|'} = ('31221101011349|DISCARD|', '...')
	report_file_counts( "Holds stuck on format", $format_callnum_keys );
	print_report( "Holds stuck on item format report", $format_callnum_keys, $items_hash_ref ) if ( $opt{'V'} );
}

# Orphaned holds; holds for titles that are not multi-volume titles, but have callnumbers with variances in holds counts relative to the title.
# param:  <none>
# return: <none>
sub audit_orphans( $ )
{
	my $master_list = shift;
	my $results = `cat "$master_list" | "$PIPE" -d'c0'`;
	my $cat_keys = create_tmp_file( "audithold_o_deduped_master", $results );
	my $differences = '';
	# Test if the file exists because sometimes theres just aren't any orphaned holds.
	if ( -s $cat_keys )
	{
		# To get the holds on a title do this:
		# 1413866|3|
		$results = `cat "$cat_keys" | selcatalog -iC -oCh 2>/dev/null`;
		my $hold_title_counts = create_tmp_file( "audithold_o_active_NA_title_holds", $results );
		# This will select all the items under a cat key with holds and count the holds on each item.
		# 1413866|1|
		# Do another selection but this time we want the holds on call numbers. We will compare that with the count on the title.
		$results = `cat "$cat_keys" | selhold -iC -a'N' -t'T' -j"ACTIVE" -oI 2>/dev/null | "$PIPE" -d'c0' -A -P | "$PIPE" -o'c1,c0' -P`;
		my $hold_item_counts = create_tmp_file( "audithold_o_active_NA_call_num_holds", $results );
		# Now diff the two files and merge the hold counts.
		$results = `echo "$hold_title_counts not $hold_item_counts" | "$DIFF" -e'c0,c1' -f'c0,c1'`;
	}
	$differences = create_tmp_file( "audithold_o_diff_title_callnum_hold_counts", $results );
	# Now weed out the items that are intransit, they create a false positive result.# But we don't want in transit items because they produce false positives.
	$results = `cat "$differences" | selitem -iN -oBmN 2>/dev/null`;
	my $items_list = create_tmp_file( "audithold_o_items_from_titles", $results );
	my $items_hash_ref = {};
	# Expected result is '31221101011349|DISCARD|1000066|36|'.
	if ( -s $items_list )
	{
		my @key_indexes    = (2,3);
		my @value_indexes  = (0);
		$items_hash_ref    = read_file_into_hash_reference( $items_list, \@key_indexes, \@value_indexes );
		# $items_hash_ref->{'31221101011349|DISCARD|'} = '1000066|'
		# Now using enlist to make lists of items for each call num key.
		$items_hash_ref = enlist_values( $items_hash_ref );
	}
	# 1000044|60|Easy readers M PBK|0|epl000001934|
	# 1525250|20|DVD MID|1|a1525250|
	# But sometimes there are no problems so...
	if ( -s $differences )
	{
		$results = `cat "$differences" | selcallnum -iC -oCNDz 2>/dev/null | selcatalog -iC -oSF 2>/dev/null | "$PIPE" -d'c0,c2' -t'c4' -P`;
	}
	else
	{
		$results = "";
	}
	my $titles = create_tmp_file( "audithold_o_title_list", $results );
	report_file_counts( "Orphaned holds", $titles );
	print_report( "Orphaned holds report", $titles, $items_hash_ref ) if ( $opt{'V'} );
}

# Audits volume holds for issues such as titles with volumes that have no visible items under call nums. Breaks out
# items in report if '-i' is used. Places an '*' infront of titles that have call nums with discarded copies. These
# seem to cause the most problem for demand management.
# param:  Name of the master list of call numbers.
# return: <none>
sub audit_volumes( $ )
{
	my $master_list = shift;
	# Input:
	# 1000066|36|Picture books D PBK|0|epl000001956
	printf STDERR "distilling items for master list.\n";
	my $results = `cat "$master_list" | selitem -iN -oNBm 2>/dev/null | "$PIPE" -t'c2'`;
	my $items_list = create_tmp_file( "audithold_v_items", $results );
	# Produces:
	# 1000066|36|31221101011349|DISCARD
	my @key_indexes       = (2,3);
	my @value_indexes     = (0,1);
	my $items_hash_ref = {};
	$items_hash_ref    = read_file_into_hash_reference( $items_list, \@key_indexes, \@value_indexes );
	# $items_hash_ref->{'31221101011349|DISCARD|'} = '1000066|36|'
	# Now using enlist to make lists of items for each call num key.
	$items_hash_ref = enlist_values( $items_hash_ref );
	# $items_hash_ref->{'1000066|36|'} = ('31221101011349|DISCARD|', '...')
	# From this list we can weed out volumes that have no visible copies with:
	$results = `cat "$master_list" | "$PIPE" -g'c2:(v|V)\\.' -d'c2,c0' | "$PIPE" -s'c0' -U`;
	my $volume_list = create_tmp_file( "audithold_v_volumes", $results );
	report_file_counts( "volumes", $volume_list );
	print_report( "Volume call nums with non-visible items report", $volume_list, $items_hash_ref );
	$results = `cat "$master_list" | "$PIPE" -g'c2:\\s+(19|20)\\d\\d' -d'c2,c0' | "$PIPE" -s'c0' -U`;
	my $annuals_list = create_tmp_file( "audithold_v_annuals", $results );
	report_file_counts( "annuals", $annuals_list );
	print_report( "Annuals with non-visible items report", $annuals_list, $items_hash_ref );
	$results = `cat "$master_list" | "$PIPE" -g'c2:(bk|BK)\.' -d'c2,c0' | "$PIPE" -s'c0' -U`;
	my $bk_list = create_tmp_file( "audithold_v_books", $results );
	report_file_counts( "book volumes", $bk_list );
	print_report( "Multi-volume books with non-visible items report", $bk_list, $items_hash_ref );
	$results = `cat "$master_list" | "$PIPE" -g'c2:\\s+(p|P)(t|T)(s|S)?\\.' -d'c2,c0' | "$PIPE" -s'c0' -U`;
	my $sets_list = create_tmp_file( "audithold_v_sets", $results );
	report_file_counts( "sets", $sets_list );
	print_report( "Sets with non-visible items report", $sets_list, $items_hash_ref );
	$results = `cat "$master_list" | "$PIPE" -g'c2:\\s+(k|K)(i|I)(t|T)' -d'c2,c0' | "$PIPE" -s'c0' -U`;
	my $kits_list = create_tmp_file( "audithold_v_kits", $results );
	report_file_counts( "kits", $kits_list );
	print_report( "Kits with non-visible items report", $kits_list, $items_hash_ref );
}

# This is an expensive list to create and we can re-use it with other operations, so do it once and let 
# subsequent audits reuse it.
# Produces:
# 1000047|38|Easy readers T PBK|0|
# 1000047|43|Easy readers T PBK|0|
# 1000051|11|Easy readers L TradePBK|0|
# param:  <none>
# return: Name of the master file.
sub init_master_hold_lists()
{
	my $file_name = "audithold_master_list";
	# if this has been done, don't run again. The script produces a uniq name for each
	# run of the script based on time.
	return $file_name if ( $MASTER_LIST and -s $MASTER_LIST ); 
	printf STDERR "creating master list.\n";
	my $results = `selhold -j"ACTIVE" -a'N' -t'T' -oC 2>/dev/null | "$PIPE" -d'c0' | selcallnum -iC -z"=0" -oNDz 2>/dev/null`;
	my $master_list = create_tmp_file( "audithold_m_tmp", $results );
	printf STDERR "refining master list.\n";
	$results = `cat "$master_list" | selcatalog -iC -oCSF 2>/dev/null | "$PIPE" -t'c4' -P`;
	my $MASTER_LIST = create_tmp_file( $file_name, $results );
	if ( ! $MASTER_LIST or ! -s $MASTER_LIST )
	{
		printf STDERR "** error creating master list.\n";
		exit 0;
	}
	return $MASTER_LIST;
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
	$MASTER_LIST = init_master_hold_lists();
}

init();
audit_formats( $MASTER_LIST ) if ( $opt{'f'} );
audit_orphans( $MASTER_LIST ) if ( $opt{'o'} );
audit_volumes( $MASTER_LIST ) if ( $opt{'v'} );
if ( $opt{'t'} )
{
	printf STDERR "Temp files will not be deleted. Please clean up '%s' when done.\n", $TEMP_DIR;
}
else
{
	clean_up();
}
# EOF
