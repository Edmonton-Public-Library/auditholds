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
#          0.5 Sept. 11, 2015 - Modularize reporting.
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
my $VERSION            = qq{0.5.05};

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
 -T: Only select titles with title level holds. Some titles have only a single hold for a system card.
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
    my $opt_string = 'etTvx';
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
# param:  result string from API calls. Consumes data like:
#     flex key | call num | item id.
#     'o754964597|DVD 782.42166 PEA PEA|929720-88001'
# return: <none>
sub print_report( $$ )
{
	printf "\n";
	printf "   Titles with problematic holds report, %s\n", $DATE;
	printf "   %s\n", shift;
	printf "  -------------------------------------------------\n";
	my @lines = split '\n', shift;
	while ( @lines )
	{
		my $line = shift @lines;
		my ( $tcn, $callnum, $id ) = split '\|', $line;
		format STDOUT =
@>>>>>>>>>>> @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< @<<<<<<<<<<<<<<<<
$tcn, $callnum, $id
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

# Creates a new list of candidate callnums whose items current location (-m) is DISCARD, and their item(s) are placeholders.
# param:  file of cat keys and their uniq call nums structured as follows.
#         cat_k  seq. callnum visible copies type of hold on title.
# return: string path of the file that contains the cat keys of titles whose only variation on callnum is ON-ORDER.
# Produces:
# 1001805|1|1|1001805-1001    |DISCARD|CD POP ROCK MET|o792891891
# 1002171|1|1|1002171-1001    |DISCARD|ON ORDER|a1002171
# 1002700|1|1|1002700-1001    |DISCARD|289.98 NEV|a1002700
# 1002865|1|1|1002865-1001    |DISCARD|JOY|a1002865
# 1003656|1|1|1003656-1001    |DISCARD|EGG|a1003656
# 1004770|2|1|1004770-2001    |DISCARD|BAB|i9781554684410
# 1004802|1|1|1004802-1001    |DISCARD|CRO|a1004802
# 1004903|1|1|1004903-1001    |DISCARD|Mystery P PBK|i9780316199865
# 1004914|1|1|1004914-1001    |DISCARD|ON ORDER|i9781409144717
# 1005622|1|1|1005622-1001    |DISCARD|ON ORDER|a1005622
sub find_discarded_temp_items( $ )
{
	my $seed_file = shift;
	# This gives a list of cat keys that don't have on order items. Once done, dedup again, uniq the catkeys and if you have 
	# more than 2 to a title you have the cat keys that have more than one, non-ON-ORDER call num. Just give us the cat keys
	# and then re-fetch the list for the new cat keys.
	my $results =  `cat "$seed_file" | "$PIPE" -d'c0' -o'c0' | "$PIPE" -s'c0' | selitem -iC -oIBm 2>/dev/null`;
	my $items = create_tmp_file( "audithold_05a_find_discarded_temp_items", $results );
	# The output will now have the item keys (0-2), ID (3), and current location (4).
	$results =  `cat "$items" | "$PIPE" -G'c3:31221' -g'c4:DISCARD' | "$PIPE" -s'c0,c1,c2'`;
	$items = create_tmp_file( "audithold_05b_find_discarded_temp_items", $results );
	# Now let's fetch the data again with these keys, get the TCN and sort them and trim white space from id and TCN.
	$results = `cat "$items" | selcallnum -iN -oNSD 2>/dev/null | selcatalog -iC -oCSF 2>/dev/null | "$PIPE" -s'c0,c1' -t'c3,c6'`;
	my $new_parred_list = create_tmp_file( "audithold_05c_find_discarded_temp_items", $results );
	return $new_parred_list;
}

# Creates a new list of candidate callnums after removing obvious multi-volume titles.
# param:  file of cat keys and their uniq call nums structured as follows.
#         cat_k  seq. callnum visible copies type of hold on title.
# return: string path of the file that contains the cat keys of titles whose only variation on callnum is ON-ORDER.
# Produces:
# 1000067|4|Easy readers M PBK|0|
# 1000067|6|Easy readers M PBK|2|
# 1000067|7|Easy readers M PBK|5|
# 1000067|8|Easy readers M PBK|1|
# 1000067|26|Easy readers M PBK|0|
# 1000067|43|Easy readers M PBK|1|
# 1000067|45|Easy readers M PBK|0|
# 1000067|46|Easy readers M PBK|0|
# 1000067|61|Easy readers M PBK|1|
# 1000067|64|E MAY|1|
sub remove_multi_volume_titles( $ )
{
	my $seed_file = shift;
	open SEED, "<$seed_file" or die "** Can't remove volume-titles because couldn't open '$seed_file', $!\n";
	my $results = '';
	while (<SEED>)
	{
		my ( $c_key, $seq, $callnum, $zero ) = split '\|', $_;
		next if ( is_multi_volume_title( $callnum ) );
		$results .= $_;
	}
	close SEED;
	my $cat_keys = create_tmp_file( "audithold_03a_remove_multi_volume_titles_cat_keys_stage1", $results );
	# If you removed the cat key with a volume, you decrease the count of callnums under a given title (catalog key).
	# If we dedup again, that cat key will be weeded out as a candidate for multi-callnum problem title.
	# The next line does this. Dedup the callnum and cat key columns, in that order. Take the results and count how
	# many unique cat keys there are, and if the count is greater than, or equal to 2, we still have multi-callnums.
	$results = `cat "$cat_keys" | "$PIPE" -d'c2,c0' | "$PIPE" -d'c0' -A -P | "$PIPE" -C'c0:ge2' -o'c1'`;
	$cat_keys = create_tmp_file( "audithold_03b_remove_multi_volume_titles_cat_keys_stage2", $results );
	# Now let's re-query the data for later processses.
	$results = `cat "$cat_keys" | selcallnum -iC -oNDz 2>/dev/null`;
	my $new_parred_list = create_tmp_file( "audithold_03c_title_no_volumes", $results );
	return $new_parred_list;
}

# Creates a new list of candidate callnums with callnums with zero visible items.
# param:  file of cat keys and their uniq call nums structured as follows.
#         cat_k  seq. callnum visible copies type of hold on title.
# return: string path of the file that contains data in format above.
# Produces:
# 1000045|18|Easy readers A PBK|0|
# 1000045|19|Easy readers A PBK|1|
# 1000045|35|Easy readers A PBK|1|
# 1000045|38|Easy readers A PBK|0|
# 1000047|38|Easy readers T PBK|0|
# 1000047|43|Easy readers T PBK|0|
# 1000047|52|Easy readers T PBK|1|
# 1000047|54|Easy readers T PBK|1|
# 1000066|9|Picture books D PBK|0|
# 1000066|21|Picture books D PBK|0|
sub create_master_list( $ )
{
	my $seed_file = shift;
	# We receive a list of call nums with zero visible items, let's flush out the list so we can see all the callnums.
	my $results = `cat "$seed_file" | "$PIPE" -d'c0' | "$PIPE" -s'c0' | selcallnum -iC -oNDz 2>/dev/null`;
	my $new_parred_list = create_tmp_file( "audithold_01a_callnums_w_zero_items_cat_keys", $results );
	return $new_parred_list;
}

# Creates a list of cat keys with callnum ids and succession of callnums..
# param:  file of cat keys and their uniq call nums structured as follows.
#         cat_k  seq. callnum visible copies type of hold on title.
# return: <none>.
# Produces:
# 1000045|18|Easy readers A PBK|0|
# 1000045|19|Easy readers A PBK|1|
# 1000045|35|Easy readers A PBK|1|
# 1000045|38|Easy readers A PBK|0|
# 1000047|38|Easy readers T PBK|0|
# 1000047|43|Easy readers T PBK|0|
# 1000047|52|Easy readers T PBK|1|
# 1000047|54|Easy readers T PBK|1|
# 1000066|9|Picture books D PBK|0|
# 1000066|21|Picture books D PBK|0|
sub report_data( $ )
{
	my $seed_file = shift;
	# We receive a list of call nums with zero visible items, let's flush out the list so we can see all the callnums.
	# 1005622|1|1|1005622-1001    |DISCARD|ON ORDER|a1005622
	my $results = `cat "$seed_file" | "$PIPE" -s'c0' | "$PIPE" -o'c6,c3,c5'`;
	my $new_parred_list = create_tmp_file( "audithold_07a_uniq_callnums", $results );
	my $count = `cat "$new_parred_list" | wc -l | "$PIPE" -W'\\s+' -o'c0'`;
	my $msg = sprintf "Possible problematic titles: %d.", $count;
	print_report( $msg, $results );
}

# finds the number of holds on a title vs. the number of holds on our suspicious item and see if they are different.
##### When there is a problem:
# 1432265|1|1|1432265-1001    |
# 1432265|11|1|31221114923878  |
# 1432265|15|2|31221114923902  |
# 1432265|17|2|31221114923910  |
# 1432265|17|3|31221114923894  |
# 1432265|19|1|31221116541702  |
# 1432265|20|2|31221116541678  |
# 1432265|21|1|31221116541660  |
# 1432265|22|1|31221116541694  |
# 1432265|23|1|31221116541686  |
# 1432265|24|1|31221114923886  |
# echo 'select count(CATALOG_KEY) from HOLD where CATALOG_KEY=1432265 and CALL_SEQUENCE=1 and COPY_NUMBER=1;' | sirsisql
# 40|
# echo 'select count(CATALOG_KEY) from HOLD where CATALOG_KEY=1432265;' | sirsisql
# 56|
##### And where there is no problem:
# echo 1003656 | selitem -iC -oIB
# 1003656|1|1|1003656-1001    |
# 1003656|48|1|31221102606048  |
# 1003656|67|1|31221101544521  |
# 1003656|74|1|31221099559135  |
# 1003656|75|1|31221099559143  |
# 1003656|76|1|31221099559127  |
# 1003656|76|2|31221101544513  |
# 1003656|77|1|31221110859464  |
# 1003656|78|1|31221102606733  |
# echo 'select count(CATALOG_KEY) from HOLD where CATALOG_KEY=1003656 and CALL_SEQUENCE=1 and COPY_NUMBER=1;' | sirsisql
# 1|
# echo 'select count(CATALOG_KEY) from HOLD where CATALOG_KEY=1003656;' | sirsisql
# 1|
sub distill_problem_holds( $ )
{
	my $seed_file = shift;
	open SEED, "<$seed_file" or die "** error, unable to open $seed_file, $!\n";
	my $results = '';
	printf "working...\n";
	while (<SEED>)
	{
		# We take the cat key, sequence, and copy number and get a count.
		my ($c_key, $seq, $copy) = split '\|', $_;
		my $item_hold_count = `echo 'select count(CATALOG_KEY) from HOLD where CATALOG_KEY=$c_key and CALL_SEQUENCE=$seq and COPY_NUMBER=$copy;' | sirsisql 2>/dev/null | "$PIPE" -t'c0'`;
		chomp $item_hold_count;
		# Sirsisql returns nothing if the query fails.
		$item_hold_count = 0 if ( ! $item_hold_count);
		# Then we take the cat key and take a count of holds.
		my $title_hold_count = `echo 'select count(CATALOG_KEY) from HOLD where CATALOG_KEY=$c_key;' | sirsisql 2>/dev/null | "$PIPE" -t'c0'`;
		chomp $title_hold_count;
		$title_hold_count = 0 if ( ! $title_hold_count);
		# Compare the two numbers and if they don't match this is a positive hit.
		if ( $item_hold_count != $title_hold_count )
		{
			$results .= $_;
		}
		printf ".";
	}
	close SEED;
	my $new_parred_list = create_tmp_file( "audithold_06a_distill_problem_holds", $results );
	return $new_parred_list;
}

init();

# This is a description of the following selection broken down by pipe boundary.
# From the HOLD table, select all active non-available holds and output the cat key.
# sort the keys.
# unique the keys.
# select from the CALLNUM table all the entries based on supplied cat keys and output the callnum key, callnum, and visible items.
my $results = '';
if ( $opt{'T'} ) # only select title holds.
{
	$results = `selhold -j"ACTIVE" -a'N' -t'T' -oC 2>/dev/null | "$PIPE" -d'c0' | selcallnum -iC -z"=0" -oNDz 2>/dev/null`;
}
else
{
	$results = `selhold -j"ACTIVE" -a'N' -oC 2>/dev/null | "$PIPE" -d'c0' | selcallnum -iC -z"=0" -oNDz 2>/dev/null`;
}
# 1000045|18|Easy readers A PBK|0|
# 1000045|38|Easy readers A PBK|0|
# 1000047|38|Easy readers T PBK|0|
# 1000047|43|Easy readers T PBK|0|
# 1000066|9|Picture books D PBK|0|
# 1000066|21|Picture books D PBK|0|
my $master_list = create_tmp_file( "audithold_00a_zero_visible_callnum_keys", $results );
# Create a master list including all the call numbers of the titles from the above list.
$master_list = create_master_list( $master_list );
$master_list = remove_multi_volume_titles( $master_list ) if ( $opt{'v'} );
$master_list = find_discarded_temp_items( $master_list );
$master_list = distill_problem_holds( $master_list );
# Collect all the flex keys and each duplicate callnum with callnum key ready for output.
report_data( $master_list );
clean_up();
# EOF
